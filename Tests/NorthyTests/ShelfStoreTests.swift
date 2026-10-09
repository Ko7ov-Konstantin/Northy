import Foundation
import Testing
@testable import Northy

@MainActor
/// Полка: дедупликация путей и уборка файлов из Drops — на временных каталогах.
struct ShelfStoreTests {

    private func url(_ path: String) -> URL {
        URL(fileURLWithPath: path)
    }

    private func tempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NorthyTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Файл, как его кладёт приём file promise: Drops/<сессия>/<имя>.
    private func makeDrop(in drops: URL, name: String) throws -> URL {
        let session = drops.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let file = session.appendingPathComponent(name)
        try Data([1, 2, 3]).write(to: file)
        return file
    }

    @Test func mergedFilesAppendsOnlyNewPaths() {
        let result = ShelfStore.mergedFiles(
            current: [url("/tmp/a"), url("/tmp/b")],
            adding: [url("/tmp/b"), url("/tmp/c")]
        )
        #expect(result.map(\.path) == ["/tmp/a", "/tmp/b", "/tmp/c"])
    }

    @Test func mergedFilesKeepsExistingOrder() {
        let result = ShelfStore.mergedFiles(
            current: [url("/tmp/x"), url("/tmp/y")],
            adding: [url("/tmp/y")]
        )
        #expect(result.map(\.path) == ["/tmp/x", "/tmp/y"], "повтор не поднимает файл наверх")
    }

    @Test func removingDropDeletesFileAndSessionFolder() throws {
        let root = tempDirectory()
        let drops = root.appendingPathComponent("Drops", isDirectory: true)
        let file = try makeDrop(in: drops, name: "Снимок экрана.png")
        let store = ShelfStore(directory: root, dropsDirectory: drops)
        store.add([file])

        store.remove(file)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(!FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
    }

    @Test func removingUserFileNeverDeletesIt() throws {
        let root = tempDirectory()
        let userFile = root.appendingPathComponent("документ.txt")
        try Data([1]).write(to: userFile)
        let store = ShelfStore(directory: root, dropsDirectory: root.appendingPathComponent("Drops"))
        store.add([userFile])

        store.remove(userFile)
        store.add([userFile])
        store.clear()
        #expect(FileManager.default.fileExists(atPath: userFile.path), "полка удаляет только свои дропы")
    }

    @Test func trashingMovesFileToTrashAndOffShelf() throws {
        let root = tempDirectory()
        let userFile = root.appendingPathComponent("запись.mov")
        try Data([1]).write(to: userFile)
        var trashed: [URL] = []
        let store = ShelfStore(directory: root, dropsDirectory: root.appendingPathComponent("Drops"), trash: { trashed.append($0) })
        store.add([userFile, url("/tmp/other")])

        #expect(store.moveToTrash(userFile))
        #expect(trashed.map(\.path) == [userFile.path])
        #expect(store.files.map(\.path) == ["/tmp/other"], "соседний файл остаётся на полке")
    }

    @Test func failedTrashKeepsFileOnShelf() throws {
        struct Refused: Error {}
        let root = tempDirectory()
        let userFile = root.appendingPathComponent("запись.mov")
        try Data([1]).write(to: userFile)
        let store = ShelfStore(directory: root, dropsDirectory: root.appendingPathComponent("Drops"), trash: { _ in throw Refused() })
        store.add([userFile])

        #expect(!store.moveToTrash(userFile))
        #expect(store.files.map(\.path) == [userFile.path])
    }

    @Test func trashingMissingFileJustLeavesShelf() {
        let root = tempDirectory()
        let missing = root.appendingPathComponent("нет.png")
        var trashed: [URL] = []
        let store = ShelfStore(directory: root, dropsDirectory: root.appendingPathComponent("Drops"), trash: { trashed.append($0) })
        store.add([missing])

        #expect(store.moveToTrash(missing))
        #expect(trashed.isEmpty)
        #expect(store.files.isEmpty)
    }

    @Test func trashingDropRemovesSessionFolder() throws {
        let root = tempDirectory()
        let drops = root.appendingPathComponent("Drops", isDirectory: true)
        let file = try makeDrop(in: drops, name: "Снимок экрана.png")
        let store = ShelfStore(directory: root, dropsDirectory: drops, trash: { try FileManager.default.removeItem(at: $0) })
        store.add([file])

        #expect(store.moveToTrash(file))
        #expect(!FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
    }

    @Test func ownsOnlyFilesInsideDrops() throws {
        let root = tempDirectory()
        let drops = root.appendingPathComponent("Drops", isDirectory: true)
        let made = try makeDrop(in: drops, name: "Запись.mov")
        let userFile = root.appendingPathComponent("документ.txt")
        try Data([1]).write(to: userFile)
        let store = ShelfStore(directory: root, dropsDirectory: drops)
        store.add([made, userFile])

        #expect(store.ownsFile(made), "снимок или запись Northy")
        #expect(!store.ownsFile(userFile), "файл, перетащенный пользователем")
    }

    @Test func clearDeletesDrops() throws {
        let root = tempDirectory()
        let drops = root.appendingPathComponent("Drops", isDirectory: true)
        let file = try makeDrop(in: drops, name: "a.png")
        let store = ShelfStore(directory: root, dropsDirectory: drops)
        store.add([file])

        store.clear()
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func initPrunesOrphanDropSessions() throws {
        let root = tempDirectory()
        let drops = root.appendingPathComponent("Drops", isDirectory: true)
        let store = ShelfStore(directory: root, dropsDirectory: drops)
        let kept = try makeDrop(in: drops, name: "kept.png")
        let orphan = try makeDrop(in: drops, name: "orphan.png")
        store.add([kept])
        store.flush()

        _ = ShelfStore(directory: root, dropsDirectory: drops)
        #expect(FileManager.default.fileExists(atPath: kept.path))
        #expect(!FileManager.default.fileExists(atPath: orphan.deletingLastPathComponent().path))
    }

    @Test func shelfSurvivesReload() {
        let root = tempDirectory()
        let store = ShelfStore(directory: root, dropsDirectory: root.appendingPathComponent("Drops"))
        store.add([url("/tmp/a"), url("/tmp/b")])
        store.flush()

        let reloaded = ShelfStore(directory: root, dropsDirectory: root.appendingPathComponent("Drops"))
        #expect(reloaded.files.map(\.path) == ["/tmp/a", "/tmp/b"])
    }
}
