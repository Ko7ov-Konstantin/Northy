import AppKit
import Observation

@MainActor
@Observable
final class ShelfStore {

    private(set) var files: [URL] = []
    /// Когда файл положили на полку (путь → дата) — для «Вставить из Northy» в Finder.
    private(set) var addedDates: [String: Date] = [:]
    private let store: JSONStore
    /// Отдельный файл: shelf.json остаётся списком путей, как в прошлых версиях.
    private let datesStore: JSONStore
    /// Сюда DropContainerView принимает file promise (скриншоты): эти копии
    /// принадлежат приложению и удаляются вместе с записью на полке.
    private let dropsDirectory: URL
    private let trash: (URL) throws -> Void

    init(
        directory: URL = AppData.directory,
        dropsDirectory: URL = AppData.dropsDirectory,
        trash: @escaping (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) {
        self.trash = trash
        store = JSONStore(url: directory.appendingPathComponent("shelf.json"))
        datesStore = JSONStore(url: directory.appendingPathComponent("shelf-added.json"))
        self.dropsDirectory = dropsDirectory
        files = store.read([String].self)?.map(URL.init(fileURLWithPath:)) ?? []
        addedDates = datesStore.read([String: Date].self) ?? [:]
        pruneOrphanDrops()
    }

    /// Отложенную debounced-запись — на диск немедленно (applicationWillTerminate).
    func flush() {
        store.flush()
        datesStore.flush()
    }

    func addedAt(_ url: URL) -> Date? {
        addedDates[url.path]
    }

    /// Файлы, положенные на полку за последние `window` секунд и ещё существующие.
    func recentFiles(now: Date = .now, window: TimeInterval = 10 * 60) -> [URL] {
        files.filter { url in
            guard let date = addedDates[url.path] else { return false }
            return now.timeIntervalSince(date) <= window && FileManager.default.fileExists(atPath: url.path)
        }
    }

    /// Дубликаты по пути не добавляются; порядок существующих не меняется —
    /// повтор не поднимает файл наверх, полка ведёт себя как стопка.
    static func mergedFiles(current: [URL], adding: [URL]) -> [URL] {
        var result = current
        for url in adding where !result.contains(where: { $0.path == url.path }) {
            result.append(url)
        }
        return result
    }

    /// Повторное добавление того же файла освежает его дату — он снова «свежий».
    func add(_ urls: [URL], at date: Date = .now) {
        files = Self.mergedFiles(current: files, adding: urls)
        store.write(files.map(\.path))
        for url in urls { addedDates[url.path] = date }
        datesStore.write(addedDates)
    }

    func remove(_ url: URL) {
        files.removeAll { $0.path == url.path }
        store.write(files.map(\.path))
        addedDates[url.path] = nil
        datesStore.write(addedDates)
        deleteIfOwnDrop(url)
    }

    /// Файл создан Northy (снимок, запись, принятый file promise) и живёт в Drops:
    /// убрать его с полки значит удалить с диска.
    func ownsFile(_ url: URL) -> Bool {
        dropSession(of: url) != nil
    }

    /// Файл — в Корзину и с полки. false — перенести не удалось, запись остаётся.
    func moveToTrash(_ url: URL) -> Bool {
        if FileManager.default.fileExists(atPath: url.path) {
            do { try trash(url) } catch { return false }
        }
        remove(url)
        return true
    }

    func clear() {
        let removed = files
        files.removeAll()
        store.write(files.map(\.path))
        addedDates.removeAll()
        datesStore.write(addedDates)
        removed.forEach(deleteIfOwnDrop)
    }

    // MARK: - Уборка Drops

    private var resolvedDrops: String {
        dropsDirectory.resolvingSymlinksInPath().path
    }

    /// Папка сессии в Drops, которой принадлежит файл; nil — файл пользователя.
    private func dropSession(of url: URL) -> URL? {
        let path = url.resolvingSymlinksInPath().path
        guard path.hasPrefix(resolvedDrops + "/") else { return nil }
        let relative = path.dropFirst(resolvedDrops.count + 1)
        guard let session = relative.split(separator: "/").first, relative.contains("/") else { return nil }
        return URL(fileURLWithPath: resolvedDrops).appendingPathComponent(String(session), isDirectory: true)
    }

    private func deleteIfOwnDrop(_ url: URL) {
        guard let session = dropSession(of: url) else { return }
        try? FileManager.default.removeItem(at: url)
        let rest = (try? FileManager.default.contentsOfDirectory(atPath: session.path)) ?? []
        if rest.isEmpty {
            try? FileManager.default.removeItem(at: session)
        }
    }

    /// Сессии Drops, ни один файл которых не лежит на полке, — от прошлых
    /// версий, не убиравших за собой.
    private func pruneOrphanDrops() {
        let used = Set(files.compactMap { dropSession(of: $0)?.lastPathComponent })
        let sessions = (try? FileManager.default.contentsOfDirectory(atPath: resolvedDrops)) ?? []
        for name in sessions where !used.contains(name) {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: resolvedDrops).appendingPathComponent(name))
        }
    }
}
