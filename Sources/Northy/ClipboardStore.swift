import AppKit
import Observation

@MainActor
@Observable
final class ClipboardStore {
    /// id — UUID, назначается один раз при создании записи: содержимое (полный
    /// текст, мегабайты Data) больше не хешируется при каждом обращении из
    /// ForEach/сравнениях, и исчезают коллизии хеша, путавшие удаление.
    struct Entry: Identifiable {
        enum Content {
            case text(String)
            case files([URL])
            case image(Data)
        }

        let id = UUID()
        let content: Content
    }

    private(set) var history: [Entry] = []
    private let maxEntries = 100
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var timer: Timer?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollPasteboard() }
        }
    }

    private func pollPasteboard() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        if pasteboard.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) == true {
            return
        }

        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            append(.files(urls))
            return
        }

        if let string = pasteboard.string(forType: .string), !string.isEmpty {
            append(.text(string))
            return
        }

        if let imageData = pasteboard.data(forType: .tiff) ?? pasteboard.data(forType: .png) {
            append(.image(imageData))
        }
    }

    /// Дубликат по содержимому не занимает вторую строку — существующая запись
    /// поднимается наверх. Сравнение по содержимому, а не по id: id уникален
    /// у каждой записи и для дедупликации не подходит.
    private func append(_ content: Entry.Content) {
        let entry = Entry(content: content)
        if let existingIndex = history.firstIndex(where: { sameContent($0.content, content) }) {
            history.remove(at: existingIndex)
        }
        history.insert(entry, at: 0)
        if history.count > maxEntries {
            history.removeLast(history.count - maxEntries)
        }
    }

    private func sameContent(_ lhs: Entry.Content, _ rhs: Entry.Content) -> Bool {
        switch (lhs, rhs) {
        case (.text(let a), .text(let b)): a == b
        case (.files(let a), .files(let b)): a.map(\.path) == b.map(\.path)
        case (.image(let a), .image(let b)): a == b
        default: false
        }
    }

    /// Копирует запись истории обратно в системный буфер. changeCount запоминается
    /// сразу после записи, чтобы следующий тик поллинга не воспринял это как новую запись.
    func copyBack(_ entry: Entry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch entry.content {
        case .text(let value):
            pasteboard.setString(value, forType: .string)
        case .files(let urls):
            pasteboard.writeObjects(urls as [NSPasteboardWriting])
        case .image(let data):
            if let image = NSImage(data: data) {
                pasteboard.writeObjects([image])
            }
        }
        lastChangeCount = pasteboard.changeCount
    }

    /// Удаляет запись только из истории — системного буфера обмена не касается.
    func remove(_ entry: Entry) {
        history.removeAll { $0.id == entry.id }
    }

    func clear() {
        history.removeAll()
    }
}
