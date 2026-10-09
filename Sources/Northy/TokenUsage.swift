import Foundation
import Observation

/// Токены по локальным логам Claude Code (~/.claude/projects/**/*.jsonl) —
/// как сканер CodexBar (CostUsageScanner+Claude): строки ответов модели с usage,
/// повтор одного ответа (возобновлённые сессии копируют историю) считается
/// один раз по message.id + requestId; стоимость — примерная, по ценам API.
nonisolated final class TokenUsageScanner: @unchecked Sendable {

    struct Row: Equatable, Sendable {
        let key: String?
        let timestamp: Date
        let model: String
        /// Счётчики, а не готовая стоимость: цены могут прийти из сети уже после разбора лога.
        let usage: TokenPricing.Usage
        /// Сессия Claude Code и её рабочая папка (cwd) — для списка сессий.
        var sessionID: String? = nil
        var project: String? = nil

        var tokens: Int { usage.total }
    }

    private struct CachedFile {
        let modified: Date
        let size: Int
        let rows: [Row]
    }

    let projectRoots: [URL]
    /// Разобранные файлы: неизменившийся лог повторно не читается.
    private var cache: [String: CachedFile] = [:]
    private let lock = NSLock()

    init(projectRoots: [URL] = TokenUsageScanner.defaultRoots()) {
        self.projectRoots = projectRoots
    }

    static func defaultRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var roots = [
            home.appendingPathComponent(".claude/projects", isDirectory: true),
            home.appendingPathComponent(".config/claude/projects", isDirectory: true),
        ]
        if let custom = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty {
            roots.insert(URL(fileURLWithPath: custom).appendingPathComponent("projects", isDirectory: true), at: 0)
        }
        return roots
    }

    /// Все ответы начиная с `since`: файлы старше по дате изменения не читаются.
    func scan(since: Date) -> [Row] {
        lock.lock()
        defer { lock.unlock() }

        var seenFiles = Set<String>()
        var keyed: [String: Row] = [:]
        var unkeyed: [Row] = []
        for file in jsonlFiles(modifiedSince: since) {
            let path = file.url.path
            seenFiles.insert(path)
            let rows: [Row]
            if let cached = cache[path], cached.modified == file.modified, cached.size == file.size {
                rows = cached.rows
            } else {
                rows = Self.parse(fileAt: file.url)
                cache[path] = CachedFile(modified: file.modified, size: file.size, rows: rows)
            }
            for row in rows where row.timestamp >= since {
                if let key = row.key { keyed[key] = row } else { unkeyed.append(row) }
            }
        }
        cache = cache.filter { seenFiles.contains($0.key) }
        return (Array(keyed.values) + unkeyed).sorted { $0.timestamp < $1.timestamp }
    }

    private func jsonlFiles(modifiedSince since: Date) -> [(url: URL, modified: Date, size: Int)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        var result: [(URL, Date, Int)] = []
        for root in projectRoots {
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true,
                      let modified = values.contentModificationDate,
                      modified >= since
                else { continue }
                result.append((url, modified, values.fileSize ?? 0))
            }
        }
        return result
    }

    static func parse(fileAt url: URL) -> [Row] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
        var rows: [Row] = []
        let assistantMarker = Data(#""type":"assistant""#.utf8)
        let usageMarker = Data(#""usage""#.utf8)
        for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            // Дешёвый фильтр по байтам до разбора JSON — логи бывают большими.
            guard line.range(of: assistantMarker) != nil, line.range(of: usageMarker) != nil else { continue }
            if let row = parse(lineData: Data(line)) { rows.append(row) }
        }
        return rows
    }

    static func parse(lines: [String]) -> [Row] {
        lines.compactMap { parse(lineData: Data($0.utf8)) }
    }

    private static func parse(lineData: Data) -> Row? {
        guard let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              object["type"] as? String == "assistant",
              let message = object["message"] as? [String: Any],
              let model = message["model"] as? String, model != "<synthetic>",
              let usage = message["usage"] as? [String: Any],
              let timestamp = parseDate(object["timestamp"] as? String)
        else { return nil }
        func count(_ key: String, in dictionary: [String: Any]? = nil) -> Int {
            max(0, ((dictionary ?? usage)[key] as? NSNumber)?.intValue ?? 0)
        }
        let counts = TokenPricing.Usage(
            input: count("input_tokens"),
            output: count("output_tokens"),
            cacheCreate: count("cache_creation_input_tokens"),
            cacheCreate1h: count("ephemeral_1h_input_tokens", in: usage["cache_creation"] as? [String: Any] ?? [:]),
            cacheRead: count("cache_read_input_tokens")
        )
        guard counts.total > 0 else { return nil }

        var key: String?
        if let messageID = message["id"] as? String {
            if let requestID = object["requestId"] as? String {
                key = "\(messageID)|\(requestID)"
            } else if let sessionID = object["sessionId"] as? String {
                key = "\(sessionID)|\(messageID)"
            }
        }
        return Row(key: key, timestamp: timestamp, model: model, usage: counts,
                   sessionID: object["sessionId"] as? String,
                   project: object["cwd"] as? String)
    }

    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }
}

/// Сводка для меню: сегодня, текущее окно 5 ч, текущая неделя лимита, текущий месяц
/// с 1 числа по дням (с разбивкой по моделям), топ-модель. Стоимость — по ценам API.
nonisolated struct TokenStats: Equatable, Sendable {
    struct ModelTotal: Equatable, Sendable {
        let model: String
        let tokens: Int
        let cost: Double
    }

    struct Day: Equatable, Sendable {
        let date: Date
        let tokens: Int
        let cost: Double
        /// По убыванию стоимости.
        let models: [ModelTotal]
    }

    let today: Int
    let todayCost: Double
    let currentSession: Int?
    let currentWeek: Int?
    let currentWeekCost: Double?
    let monthStart: Date
    let monthToDate: Int
    let monthToDateCost: Double
    /// С 1 числа по сегодня, по дню на число.
    let daily: [Day]
    let topModel: String?

    /// Есть что показать: расход в этом месяце или в недельном окне, начатом в прошлом.
    var hasUsage: Bool { monthToDate > 0 || (currentWeek ?? 0) > 0 }

    static func monthStart(now: Date, calendar: Calendar = .current) -> Date {
        calendar.dateInterval(of: .month, for: now)?.start ?? calendar.startOfDay(for: now)
    }

    /// С какого момента читать логи: с 1 числа, но не позже чем неделю назад —
    /// в начале месяца недельное окно лимита началось ещё в прошлом.
    static func scanStart(now: Date, calendar: Calendar = .current) -> Date {
        let todayStart = calendar.startOfDay(for: now)
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: todayStart) ?? todayStart
        return min(weekAgo, monthStart(now: now, calendar: calendar))
    }

    static func make(rows: [TokenUsageScanner.Row], now: Date, sessionStart: Date?, weekStart: Date?, calendar: Calendar = .current, prices: [String: TokenPricing.Rates] = [:]) -> TokenStats {
        let todayStart = calendar.startOfDay(for: now)
        let firstDay = monthStart(now: now, calendar: calendar)
        let dayCount = (calendar.dateComponents([.day], from: firstDay, to: todayStart).day ?? 0) + 1
        let recent = rows.filter { $0.timestamp >= firstDay && $0.timestamp <= now }
        // Цена ищется один раз на модель, а не на каждую строку лога.
        let rates = Dictionary(uniqueKeysWithValues: Set(rows.map(\.model)).compactMap { model in
            TokenPricing.rates(for: model, loaded: prices).map { (model, $0) }
        })
        func cost(_ row: TokenUsageScanner.Row) -> Double {
            rates[row.model].map { TokenPricing.cost(row.usage, rates: $0) } ?? 0
        }

        var perDay: [Date: [String: (tokens: Int, cost: Double)]] = [:]
        var perModel: [String: Int] = [:]
        for row in recent {
            let day = calendar.startOfDay(for: row.timestamp)
            let current = perDay[day, default: [:]][row.model] ?? (0, 0)
            perDay[day, default: [:]][row.model] = (current.tokens + row.tokens, current.cost + cost(row))
            perModel[row.model, default: 0] += row.tokens
        }
        let daily = (0..<dayCount).compactMap { offset -> Day? in
            guard let day = calendar.date(byAdding: .day, value: offset, to: firstDay) else { return nil }
            let models = (perDay[day] ?? [:])
                .map { ModelTotal(model: $0.key, tokens: $0.value.tokens, cost: $0.value.cost) }
                .sorted { $0.cost == $1.cost ? $0.tokens > $1.tokens : $0.cost > $1.cost }
            return Day(
                date: day,
                tokens: models.reduce(0) { $0 + $1.tokens },
                cost: models.reduce(0) { $0 + $1.cost },
                models: models
            )
        }
        func window(since start: Date?) -> (tokens: Int, cost: Double)? {
            guard let start else { return nil }
            let inWindow = rows.filter { $0.timestamp >= start && $0.timestamp <= now }
            return (inWindow.reduce(0) { $0 + $1.tokens }, inWindow.reduce(0) { $0 + cost($1) })
        }
        let today = daily.last { $0.date == todayStart }
        let week = window(since: weekStart)
        return TokenStats(
            today: today?.tokens ?? 0,
            todayCost: today?.cost ?? 0,
            currentSession: window(since: sessionStart)?.tokens,
            currentWeek: week?.tokens,
            currentWeekCost: week?.cost,
            monthStart: firstDay,
            monthToDate: daily.reduce(0) { $0 + $1.tokens },
            monthToDateCost: daily.reduce(0) { $0 + $1.cost },
            daily: daily,
            topModel: perModel.max { $0.value < $1.value }?.key
        )
    }
}

/// Сканирование логов в фоне по открытию меню, не чаще раза в минуту.
@MainActor
@Observable
final class TokenStatsStore {
    private(set) var rows: [TokenUsageScanner.Row] = []
    /// Сессии Claude Code за сутки — пересчитываются после каждого сканирования.
    private(set) var sessions: [ClaudeSession] = []
    private(set) var hasScanned = false
    private(set) var isScanning = false

    /// Цены из сети (или с диска с прошлого раза); пусто — работает встроенная таблица.
    private(set) var prices: [String: TokenPricing.Rates] = [:]

    /// Время последней удачной загрузки цен; nil — цены ещё не скачивались.
    private(set) var pricesFetchedAt: Date?
    private(set) var isFetchingPrices = false
    /// Последняя попытка загрузки не удалась (прежние цены остаются в силе).
    private(set) var priceFetchFailed = false

    private let scanner: TokenUsageScanner
    private let downloadPrices: @Sendable () async -> [String: TokenPricing.Rates]?
    private let pricesURL: URL
    private var lastScan: Date?
    private var nextPriceCheck = Date.distantPast
    private(set) var priceTask: Task<Void, Never>?

    init(
        scanner: TokenUsageScanner = TokenUsageScanner(),
        downloadPrices: @escaping @Sendable () async -> [String: TokenPricing.Rates]? = { await TokenPricing.download() },
        pricesURL: URL = TokenPricing.savedURL
    ) {
        self.scanner = scanner
        self.downloadPrices = downloadPrices
        self.pricesURL = pricesURL
        if let saved = TokenPricing.readSaved(from: pricesURL) {
            prices = saved.rates
            pricesFetchedAt = saved.fetchedAt
            nextPriceCheck = min(saved.fetchedAt, .now) + 24 * 3600
        }
    }

    /// Раз в сутки; неудача — повтор не раньше чем через час. Строки хранят счётчики,
    /// поэтому новые цены видны сразу, без пересканирования логов.
    private func refreshPricesIfDue(now: Date) {
        guard now >= nextPriceCheck, !isFetchingPrices else { return }
        priceTask = Task { await fetchPrices(now: now) }
    }

    /// Ручное обновление (кнопка в настройках): не смотрит на расписание.
    func refreshPricesNow(now: Date = .now) async {
        await fetchPrices(now: now)
    }

    private func fetchPrices(now: Date) async {
        guard !isFetchingPrices else { return }
        isFetchingPrices = true
        nextPriceCheck = now + 3600
        defer { isFetchingPrices = false }
        let download = downloadPrices
        guard let fresh = await Task.detached(priority: .utility, operation: { await download() }).value else {
            priceFetchFailed = true
            return
        }
        priceFetchFailed = false
        nextPriceCheck = now + 24 * 3600
        prices = fresh
        pricesFetchedAt = now
        sessions = ClaudeSessions.make(rows: rows, prices: fresh)
        let file = pricesURL
        await Task.detached(priority: .utility) { TokenPricing.write(.init(fetchedAt: now, rates: fresh), to: file) }.value
    }

    func refresh(force: Bool = false, now: Date = .now) async {
        refreshPricesIfDue(now: now)
        guard !isScanning else { return }
        if !force, let lastScan, now.timeIntervalSince(lastScan) < 60 { return }
        lastScan = now
        isScanning = true
        defer { isScanning = false }
        let since = TokenStats.scanStart(now: now)
        let scanner = scanner
        rows = await Task.detached(priority: .utility) { scanner.scan(since: since) }.value
        sessions = ClaudeSessions.make(rows: rows, now: now, prices: prices)
        hasScanned = true
    }

    func stats(for snapshot: UsageSnapshot?, now: Date = .now) -> TokenStats {
        let session = snapshot?.windows.first { $0.kind == .session }?.resetsAt.map { $0 - UsagePace.duration(of: .session) }
        let week = snapshot?.windows.first { $0.kind == .weekly }?.resetsAt.map { $0 - UsagePace.duration(of: .weekly) }
        return TokenStats.make(rows: rows, now: now, sessionStart: session, weekStart: week, prices: prices)
    }
}
