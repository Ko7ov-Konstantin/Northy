import Foundation

/// Каталог данных приложения: ~/Library/Application Support/Northy/.
/// Рядом с ним лежит Drops (дропы file promise) и Images (оригиналы картинок
/// из истории буфера).
enum AppData {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Northy", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var imagesDirectory: URL {
        let dir = directory.appendingPathComponent("Images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Дропы file promise: каждая drag-сессия кладёт файлы в свою подпапку,
    /// чтобы одинаковые имена (типичный случай — скриншоты) не перезаписывали
    /// друг друга.
    static var dropsDirectory: URL {
        let dir = directory.appendingPathComponent("Drops", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// JSON-файл с дебаунсом записи: изменения истории приходят пачками (каждое
/// копирование в буфер, удаление строк), а писать на диск на каждое — незачем.
/// flush() вызывается при завершении приложения, чтобы последняя отложенная
/// запись не потерялась.
@MainActor
final class JSONStore {
    private let url: URL
    private let debounce: TimeInterval
    private var workItem: DispatchWorkItem?
    private var pendingWrite: (() -> Void)?

    init(url: URL, debounce: TimeInterval = 0.5) {
        self.url = url
        self.debounce = debounce
    }

    func read<T: Decodable>(_ type: T.Type) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    func write<T: Encodable>(_ value: T) {
        pendingWrite = { [url] in
            if let data = try? JSONEncoder().encode(value) {
                try? data.write(to: url, options: .atomic)
            }
        }
        workItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.writePendingNow() }
        workItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: item)
    }

    /// Немедленно выполняет отложенную запись, если она есть.
    func flush() {
        workItem?.cancel()
        workItem = nil
        writePendingNow()
    }

    private func writePendingNow() {
        pendingWrite?()
        pendingWrite = nil
    }
}
