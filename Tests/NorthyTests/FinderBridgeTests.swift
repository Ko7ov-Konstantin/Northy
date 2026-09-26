import Foundation
import Testing
@testable import Northy

@MainActor
/// Мост с расширением Finder: свежие файлы полки, команды с секретом, копирование.
struct FinderBridgeTests {

    private func tempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NorthyTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeFile(_ name: String, in dir: URL, contents: String = "x") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    // MARK: полка помнит, когда файл добавлен

    @Test func shelfRemembersAddedDatesAcrossReload() throws {
        let root = tempDirectory()
        let file = try makeFile("a.txt", in: root)
        let store = ShelfStore(directory: root, dropsDirectory: root.appendingPathComponent("Drops"))
        let t0 = Date(timeIntervalSince1970: 1_000)
        store.add([file], at: t0)
        #expect(store.addedAt(file) == t0)

        // Повторная отправка того же файла делает его снова свежим.
        let t1 = Date(timeIntervalSince1970: 2_000)
        store.add([file], at: t1)
        #expect(store.files.count == 1)
        #expect(store.addedAt(file) == t1)
        store.flush()

        let reloaded = ShelfStore(directory: root, dropsDirectory: root.appendingPathComponent("Drops"))
        #expect(reloaded.addedAt(file) == t1)
        reloaded.remove(file)
        #expect(reloaded.addedAt(file) == nil)
    }

    @Test func recentFilesAreWithinTenMinutesAndExist() throws {
        let root = tempDirectory()
        let fresh = try makeFile("fresh.txt", in: root)
        let old = try makeFile("old.txt", in: root)
        let gone = root.appendingPathComponent("gone.txt")
        let store = ShelfStore(directory: root, dropsDirectory: root.appendingPathComponent("Drops"))
        let now = Date(timeIntervalSince1970: 10_000)
        store.add([old], at: now - 11 * 60)
        store.add([fresh, gone], at: now - 60)
        #expect(store.recentFiles(now: now).map(\.lastPathComponent) == ["fresh.txt"])
    }

    // MARK: команды от расширения

    @Test func requestNeedsMatchingSecret() {
        let token = "secret-123"
        let send = #"{"token":"secret-123","action":"send","paths":["/Users/me/a.pdf","/Users/me/b.png"]}"#
        #expect(FinderBridge.parseRequest(send, token: token) == .send([URL(fileURLWithPath: "/Users/me/a.pdf"), URL(fileURLWithPath: "/Users/me/b.png")]))

        let paste = #"{"token":"secret-123","action":"paste","paths":["/Users/me/Desktop"]}"#
        #expect(FinderBridge.parseRequest(paste, token: token) == .paste(into: URL(fileURLWithPath: "/Users/me/Desktop")))

        #expect(FinderBridge.parseRequest(send.replacingOccurrences(of: "secret-123", with: "guess"), token: token) == nil, "чужой секрет")
        #expect(FinderBridge.parseRequest(#"{"action":"send","paths":["/a"]}"#, token: token) == nil, "без секрета")
        #expect(FinderBridge.parseRequest(#"{"token":"secret-123","action":"rm","paths":["/a"]}"#, token: token) == nil)
        #expect(FinderBridge.parseRequest(#"{"token":"secret-123","action":"send","paths":["relative/path"]}"#, token: token) == nil, "только абсолютные пути")
        #expect(FinderBridge.parseRequest(#"{"token":"secret-123","action":"send","paths":[]}"#, token: token) == nil)
        #expect(FinderBridge.parseRequest("не json", token: token) == nil)
    }

    @Test func stateFileIsPrivateAndReadable() throws {
        let root = tempDirectory()
        let file = try makeFile("отчёт.pdf", in: root)
        let url = root.appendingPathComponent("finder-bridge.json")
        try FinderBridge.writeState(token: "t", recent: [(file, Date(timeIntervalSince1970: 500))], to: url)

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "секрет читает только владелец")
        let state = try JSONDecoder().decode(FinderBridge.State.self, from: Data(contentsOf: url))
        #expect(state.token == "t")
        #expect(state.recent.map(\.name) == ["отчёт.pdf"])
        #expect(state.recent.first?.addedAt == 500)
    }

    // MARK: вставка

    @Test func uniqueNameLikeFinder() {
        let dir = URL(fileURLWithPath: "/tmp/x")
        let taken: Set<String> = ["/tmp/x/a.png", "/tmp/x/a 2.png", "/tmp/x/README"]
        let exists: (URL) -> Bool = { taken.contains($0.path) }
        #expect(FinderBridge.uniqueDestination(for: "a.png", in: dir, exists: exists).lastPathComponent == "a 3.png")
        #expect(FinderBridge.uniqueDestination(for: "README", in: dir, exists: exists).lastPathComponent == "README 2")
        #expect(FinderBridge.uniqueDestination(for: "new.txt", in: dir, exists: exists).lastPathComponent == "new.txt")
    }

    @Test func pasteCopiesWithoutOverwriting() throws {
        let source = tempDirectory()
        let target = tempDirectory()
        let file = try makeFile("a.txt", in: source, contents: "новый")
        _ = try makeFile("a.txt", in: target, contents: "старый")

        let copied = try FinderBridge.paste([file], into: target)
        #expect(copied.map(\.lastPathComponent) == ["a 2.txt"])
        #expect(try String(contentsOf: target.appendingPathComponent("a.txt"), encoding: .utf8) == "старый")
        #expect(try String(contentsOf: target.appendingPathComponent("a 2.txt"), encoding: .utf8) == "новый")
        #expect(FileManager.default.fileExists(atPath: file.path), "исходник остаётся на месте")
    }

    @Test func pasteRefusesNonDirectoryAndSandboxContainers() throws {
        let source = tempDirectory()
        let file = try makeFile("a.txt", in: source)
        #expect(throws: FinderBridge.PasteError.notADirectory) { try FinderBridge.paste([file], into: file) }
        let container = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.example.app/Data")
        #expect(throws: FinderBridge.PasteError.protectedLocation) { try FinderBridge.paste([file], into: container) }
    }
}
