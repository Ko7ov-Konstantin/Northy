import AppKit
import Observation

@MainActor
@Observable
final class ClipboardStore {

    /// id — UUID, назначается один раз при создании записи: содержимое не
    /// хешируется при каждом обращении из ForEach.
    struct Entry: Identifiable, Codable {
        enum Content {
            case text(String)
            case files([URL])
            case image(ImageRef)
        }

        let id: UUID
        let content: Content
        /// nil у записей из версий, где дата не сохранялась.
        let date: Date?
        /// Закреплённая запись не вытесняется лимитом и не стирается «Очистить».
        var isPinned: Bool

        init(id: UUID = UUID(), content: Content, date: Date? = .now, isPinned: Bool = false) {
            self.id = id
            self.content = content
            self.date = date
            self.isPinned = isPinned
        }

        private enum CodingKeys: String, CodingKey {
            case id, content, date, isPinned
        }

        /// В прошлых версиях ключа isPinned не было — такие записи не закреплены.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            content = try container.decode(Content.self, forKey: .content)
            date = try container.decodeIfPresent(Date.self, forKey: .date)
            isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        }
    }

    /// Фильтр истории по типу записи.
    enum KindFilter: String, CaseIterable, Identifiable {
        case all = "Все"
        case text = "Текст"
        case files = "Файлы"
        case images = "Картинки"

        var id: Self { self }
    }

    /// Тексты длиннее — усекаются до лимита с маркером в конце.
    static let textByteLimit = 1_000_000
    static let previewLimit = 240

    private(set) var history: [Entry] = []
    let imagesDirectory: URL
    /// Сколько незакреплённых записей хранится; уменьшение сразу срезает лишние старые.
    var limit: Int {
        didSet {
            guard limit != oldValue else { return }
            commit(Self.trimmed(history.reversed(), limit: limit).reversed())
        }
    }
    /// Сколько записей можно закрепить; уменьшение уже закреплённые не трогает.
    var pinLimit = 5
    private let store: JSONStore
    private var lastChangeCount = 0
    private var timer: Timer?

    init(directory: URL = AppData.directory, limit: Int = 100) {
        self.limit = limit
        store = JSONStore(url: directory.appendingPathComponent("clipboard.json"))
        imagesDirectory = directory.appendingPathComponent("Images", isDirectory: true)
        try? FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
    }

    func start() {
        load()
        lastChangeCount = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollPasteboard() }
        }
    }

    /// Читает историю, переносит base64-картинки старого формата в файлы и
    /// удаляет из Images всё, на что история больше не ссылается.
    func load() {
        var loaded = store.read([Entry].self) ?? []
        var migrated = false
        loaded = loaded.compactMap { entry in
            guard case .image(let ref) = entry.content, let data = ref.legacyData else { return entry }
            migrated = true
            guard let stored = ClipboardImages.store(data, in: imagesDirectory) else { return nil }
            return Entry(id: entry.id, content: .image(stored), date: entry.date)
        }
        history = loaded
        if migrated { store.write(history) }
        pruneOrphanImages()
    }

    /// Отложенную debounced-запись — на диск немедленно (applicationWillTerminate).
    func flush() {
        store.flush()
    }

    func imageURL(for ref: ImageRef) -> URL {
        imagesDirectory.appendingPathComponent(ref.filename)
    }

    private func pollPasteboard() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        if Self.shouldIgnore(types: pasteboard.types) { return }

        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            add(.files(urls))
            return
        }

        if let string = pasteboard.string(forType: .string), !string.isEmpty {
            add(.text(Self.truncated(string)))
            return
        }

        if let raw = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            // Перекодирование большого скриншота в PNG — не на главном потоке.
            let directory = imagesDirectory
            Task {
                let ref = await Task.detached(priority: .utility) {
                    ClipboardImages.store(raw, in: directory)
                }.value
                if let ref { add(.image(ref)) }
            }
        }
    }

    // MARK: - Чистая логика (тестируется без NSPasteboard)

    /// Менеджеры паролей и служебные записи помечают буфер этими типами
    /// (nspasteboard.org) — такие значения в историю не попадают.
    static let ignoredTypes: Set<NSPasteboard.PasteboardType> = [
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
        NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"),
    ]

    static func shouldIgnore(types: [NSPasteboard.PasteboardType]?) -> Bool {
        guard let types else { return false }
        return types.contains(where: ignoredTypes.contains)
    }

    /// Вставка новой записи в хронологический лог (старые — в начале) с
    /// дедупликацией и лимитом: повтор по содержимому не занимает вторую
    /// строку — старая запись удаляется; при переполнении выпадает самое
    /// старое. Результат — в порядке отображения: новые сверху.
    static func merged(history: [Entry], appending entry: Entry, limit: Int) -> [Entry] {
        var entry = entry
        // Повтор закреплённой записи поднимается наверх, но остаётся закреплённым.
        if history.contains(where: { $0.isPinned && sameContent($0.content, entry.content) }) {
            entry.isPinned = true
        }
        var chronological = history.filter { !sameContent($0.content, entry.content) }
        chronological.append(entry)
        return trimmed(chronological, limit: limit).reversed()
    }

    /// Лимит считает только незакреплённые; выпадают самые старые из них.
    static func trimmed(_ chronological: [Entry], limit: Int) -> [Entry] {
        var excess = chronological.filter { !$0.isPinned }.count - limit
        guard excess > 0 else { return chronological }
        var result: [Entry] = []
        for entry in chronological {
            if excess > 0, !entry.isPinned {
                excess -= 1
                continue
            }
            result.append(entry)
        }
        return result
    }

    /// Поиск без учёта регистра по тексту (первые 20 000 символов) и именам
    /// файлов, плюс фильтр по типу. Пустой запрос — только фильтр.
    static func filtered(_ entries: [Entry], query: String, kind: KindFilter) -> [Entry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { entry in
            switch (kind, entry.content) {
            case (.all, _), (.text, .text), (.files, .files), (.images, .image): break
            default: return false
            }
            guard !needle.isEmpty else { return true }
            switch entry.content {
            case .text(let value):
                return String(value.prefix(20_000)).localizedStandardContains(needle)
            case .files(let urls):
                return urls.contains { $0.lastPathComponent.localizedStandardContains(needle) }
            case .image:
                return "изображение картинка".localizedStandardContains(needle)
            }
        }
    }

    static func sameContent(_ lhs: Entry.Content, _ rhs: Entry.Content) -> Bool {
        switch (lhs, rhs) {
        case (.text(let a), .text(let b)): a == b
        case (.files(let a), .files(let b)): a.map(\.path) == b.map(\.path)
        case (.image(let a), .image(let b)): a.filename == b.filename
        default: false
        }
    }

    /// Текст сверх лимита режется по границе UTF-8: недорезанный символ
    /// отбрасывается целиком (без U+FFFD), в конце — маркер усечения.
    static func truncated(_ text: String) -> String {
        guard text.utf8.count > textByteLimit else { return text }
        var bytes = Array(text.utf8.prefix(textByteLimit))
        while let last = bytes.last, last & 0xC0 == 0x80 {
            bytes.removeLast()
        }
        return String(decoding: bytes, as: UTF8.self) + "[усечено до 1 МБ]"
    }

    /// Строка для списка: пробелы и переносы схлопнуты, длина ограничена —
    /// мегабайтный текст не обрабатывается целиком на каждой перерисовке.
    static func preview(of text: String) -> String {
        let head = text.prefix(previewLimit * 4)
        let collapsed = head.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(collapsed.prefix(previewLimit))
    }

    // MARK: - Мутации

    func add(_ content: Entry.Content) {
        // history хранится новые-сверху, merged принимает хронологический лог.
        commit(Self.merged(history: history.reversed(), appending: Entry(content: content), limit: limit))
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
        case .image(let ref):
            if let image = NSImage(contentsOf: imageURL(for: ref)) {
                pasteboard.writeObjects([image])
            }
        }
        lastChangeCount = pasteboard.changeCount
    }

    /// Удаляет запись только из истории — системного буфера обмена не касается.
    func remove(_ entry: Entry) {
        commit(history.filter { $0.id != entry.id })
    }

    /// Стирает незакреплённые записи — закреплённые остаются.
    func clear() {
        commit(history.filter(\.isPinned))
    }

    /// Можно ли закрепить ещё одну запись.
    var canPin: Bool { history.filter(\.isPinned).count < pinLimit }

    /// false — закрепить нельзя: уже закреплено pinLimit записей. Открепить можно всегда.
    @discardableResult
    func togglePin(_ entry: Entry) -> Bool {
        let pinning = history.first { $0.id == entry.id }.map { !$0.isPinned } ?? false
        if pinning, !canPin { return false }
        commit(history.map { item in
            guard item.id == entry.id else { return item }
            var toggled = item
            toggled.isPinned.toggle()
            return toggled
        })
        return true
    }

    /// Файлы картинок, выпавших из истории (удаление, лимит, очистка), — с диска.
    private func commit(_ newHistory: [Entry]) {
        let kept = Self.imageFilenames(in: newHistory)
        for name in Self.imageFilenames(in: history).subtracting(kept) {
            try? FileManager.default.removeItem(at: imagesDirectory.appendingPathComponent(name))
        }
        history = newHistory
        store.write(history)
    }

    private func pruneOrphanImages() {
        let referenced = Self.imageFilenames(in: history)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: imagesDirectory.path)) ?? []
        for name in names where !referenced.contains(name) {
            try? FileManager.default.removeItem(at: imagesDirectory.appendingPathComponent(name))
        }
    }

    private static func imageFilenames(in entries: [Entry]) -> Set<String> {
        Set(entries.compactMap { entry in
            if case .image(let ref) = entry.content { return ref.filename }
            return nil
        })
    }
}

/// Формат совместим с синтезированным Codable прошлых версий
/// ({"text":{"_0":…}}); картинка раньше лежала там же как base64 Data.
extension ClipboardStore.Entry.Content: Codable {
    private enum Kind: String, CodingKey { case text, files, image }
    private enum Payload: String, CodingKey { case value = "_0" }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Kind.self)
        guard let kind = container.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "пустой content"))
        }
        let payload = try container.nestedContainer(keyedBy: Payload.self, forKey: kind)
        switch kind {
        case .text:
            self = .text(try payload.decode(String.self, forKey: .value))
        case .files:
            self = .files(try payload.decode([URL].self, forKey: .value))
        case .image:
            if let ref = try? payload.decode(ImageRef.self, forKey: .value) {
                self = .image(ref)
            } else {
                let data = try payload.decode(Data.self, forKey: .value)
                self = .image(ImageRef(filename: "", pixelWidth: 0, pixelHeight: 0, legacyData: data))
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Kind.self)
        switch self {
        case .text(let value):
            var payload = container.nestedContainer(keyedBy: Payload.self, forKey: .text)
            try payload.encode(value, forKey: .value)
        case .files(let urls):
            var payload = container.nestedContainer(keyedBy: Payload.self, forKey: .files)
            try payload.encode(urls, forKey: .value)
        case .image(let ref):
            var payload = container.nestedContainer(keyedBy: Payload.self, forKey: .image)
            try payload.encode(ref, forKey: .value)
        }
    }
}
