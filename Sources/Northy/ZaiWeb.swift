import Foundation
import Observation
import Security

/// Лимиты GLM Coding Plan по API-ключу Z.AI — тот же запрос, что у CodexBar:
/// GET /api/monitor/usage/quota/limit с заголовком Authorization: Bearer.
/// Ключ уходит только на https://api.z.ai и нигде не логируется.
nonisolated enum ZaiWeb {

    static let quotaURL = URL(string: "https://api.z.ai/api/monitor/usage/quota/limit")!
    static let dashboardURL = URL(string: "https://z.ai/manage-apikey/coding-plan/personal/my-plan")!

    enum FetchError: LocalizedError, Equatable {
        case noKey
        case keychainDenied
        case unauthorized
        case rateLimited
        case server(Int)
        case invalidResponse
        case noLimits

        var errorDescription: String? {
            switch self {
            case .noKey:
                "Ключ Z.AI не задан — добавьте его в настройках Northy"
            case .keychainDenied:
                "Нет доступа к ключу Z.AI в Связке ключей — разрешите доступ в запросе macOS"
            case .unauthorized:
                "Z.AI не принял ключ — проверьте его в настройках Northy"
            case .rateLimited:
                "Z.AI просит подождать — попробуйте через пару минут"
            case .server(let code):
                "Z.AI ответил ошибкой \(code)"
            case .invalidResponse:
                "Не удалось разобрать ответ Z.AI"
            case .noLimits:
                "Ключ Z.AI принят, но подписки GLM Coding Plan у него нет — лимиты появятся после её оформления"
            }
        }
    }

    static func request(apiKey: String) -> URLRequest {
        var request = URLRequest(url: quotaURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    static func error(forStatus status: Int) -> FetchError {
        switch status {
        case 401, 403: .unauthorized
        case 429: .rateLimited
        default: .server(status)
        }
    }

    // MARK: - Ответ

    private struct Limit {
        let isTools: Bool
        let isCredits: Bool
        let usage: Int?
        let remaining: Int?
        /// Расход MCP по инструментам: «search-prime — 210».
        let tools: [UsageDetail]
        let percent: Double
        /// nil — длительность окна сервер не назвал понятно.
        let duration: TimeInterval?
        let label: String?
        let resetsAt: Date?
    }

    /// Ошибки авторизации Z.AI отдаёт с HTTP 200 и кодом внутри тела.
    static func parseQuota(_ data: Data, now: Date = .now) throws -> UsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = integer(root["code"])
        else { throw FetchError.invalidResponse }
        guard code == 200, root["success"] as? Bool == true else {
            if code == 401 || code == 1001 { throw FetchError.unauthorized }
            // Ключу без подписки Z.AI отвечает кодом 500 и текстом про coding plan.
            let message = (root["msg"] as? String ?? "").lowercased()
            throw message.contains("coding plan") ? FetchError.noLimits : FetchError.server(code)
        }
        guard let payload = root["data"] as? [String: Any], let rawLimits = payload["limits"] as? [Any] else {
            throw FetchError.invalidResponse
        }

        let limits = rawLimits.compactMap { limit(from: $0, now: now) }
        // Окна тарифа — от короткого к длинному; лимит инструментов MCP — последним.
        let plan = limits.filter { !$0.isTools }.sorted { ($0.duration ?? .infinity) < ($1.duration ?? .infinity) }
        let tools = limits.last { $0.isTools }

        var windows: [UsageWindow] = []
        for limit in plan + [tools].compactMap({ $0 }) {
            let kind = kind(of: limit)
            guard !windows.contains(where: { $0.kind == kind }) else { continue }
            // Длина окна неизвестна — 0: темп расхода для такого окна не считается.
            windows.append(UsageWindow(kind: kind, percent: limit.percent, resetsAt: limit.resetsAt, duration: limit.duration ?? 0))
        }
        guard !windows.isEmpty else { throw FetchError.noLimits }

        let planName = ["planName", "plan", "plan_type", "packageName", "level"].lazy
            .compactMap { (payload[$0] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        var snapshot = UsageSnapshot(windows: windows, fetchedAt: now, plan: planName.map { String($0.prefix(40)) })
        snapshot.usesCredits = plan.contains(where: \.isCredits)
        // Как в CodexBar: общая квота — по самому длинному окну, квота сеанса — по короткому.
        if let longest = plan.last {
            snapshot.details.append(detail(longest.isCredits ? "Квота кредитов" : "Квота токенов", longest))
        }
        if plan.count >= 2, let shortest = plan.first {
            snapshot.details.append(detail(shortest.isCredits ? "Квота кредитов сеанса" : "Квота сеанса", shortest))
        }
        if let tools {
            snapshot.details.append(detail("Квота MCP", tools))
            snapshot.details += tools.tools
        }
        return snapshot
    }

    private static func detail(_ label: String, _ limit: Limit) -> UsageDetail {
        let percent = limit.percent.formatted(.number.precision(.fractionLength(0...1)).locale(Locale(identifier: "ru_RU")))
        var parts: [String] = []
        if let usage = limit.usage { parts.append("лимит \(count(usage))") }
        if let remaining = limit.remaining { parts.append("осталось \(count(remaining))") }
        return UsageDetail(label: label, value: "\(percent)% использовано", note: parts.isEmpty ? nil : parts.joined(separator: " · "))
    }

    /// Небольшие числа (вызовы MCP) — точно, большие (токены) — «40 млн».
    private static func count(_ value: Int) -> String {
        value < 100_000 ? String(value) : Formatting.tokens(value)
    }

    // MARK: - Токены по моделям

    static let modelUsageURL = URL(string: "https://api.z.ai/api/monitor/usage/model-usage")!

    /// Период — с начала дня daysBack дней назад до конца текущего часа, в местном времени.
    static func modelUsageRequest(apiKey: String, daysBack: Int, now: Date = .now, calendar: Calendar = .current) -> URLRequest {
        let start = calendar.date(byAdding: .day, value: -max(1, daysBack), to: calendar.startOfDay(for: now)) ?? now
        let hour = calendar.dateInterval(of: .hour, for: now)?.end ?? now
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        var components = URLComponents(url: modelUsageURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "startTime", value: formatter.string(from: start)),
            URLQueryItem(name: "endTime", value: formatter.string(from: hour - 1)),
        ]
        var request = request(apiKey: apiKey)
        request.url = components.url
        return request
    }

    /// Необязательная аналитика: пустой, слишком большой или странный ответ — nil, лимиты от него не зависят.
    static func parseModelUsage(_ data: Data, title: String) -> UsageSeries? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              integer(root["code"]) == 200, root["success"] as? Bool == true,
              let payload = root["data"] as? [String: Any],
              let labels = payload["x_time"] as? [Any], labels.count <= 120,
              let models = payload["modelDataList"] as? [[String: Any]], models.count <= 200
        else { return nil }

        var points = labels.map { UsageSeries.Point(label: "\($0)", value: 0) }
        var totals: [UsageSeries.Total] = []
        for model in models {
            let values = (model["tokensUsage"] as? [Any] ?? []).prefix(labels.count)
            guard values.allSatisfy({ $0 is NSNull || integer($0) != nil }) else { return nil }
            let tokens = values.map { max(0, integer($0) ?? 0) }
            for (index, value) in tokens.enumerated() {
                points[index] = .init(label: points[index].label, value: points[index].value + value)
            }
            let total = tokens.reduce(0, +)
            if total > 0 { totals.append(.init(name: model["modelName"] as? String ?? "", tokens: total)) }
        }
        points = points.filter { $0.value > 0 }
        totals.sort { $0.tokens == $1.tokens ? $0.name < $1.name : $0.tokens > $1.tokens }
        totals = Array(totals.prefix(20))
        guard !points.isEmpty, (points.map(\.label) + totals.map(\.name)).allSatisfy(isDisplayable) else { return nil }
        return UsageSeries(title: title, points: points, totals: totals)
    }

    private static func isDisplayable(_ text: String) -> Bool {
        text.count <= 120 && text.unicodeScalars.contains { !$0.properties.isWhitespace && $0.properties.generalCategory != .format && $0.properties.generalCategory != .control }
    }

    private static func kind(of limit: Limit) -> UsageWindow.Kind {
        if limit.isTools { return .custom(limit.duration == 30 * 86_400 ? "MCP · месяц" : "MCP") }
        switch limit.duration {
        case 5 * 3600: return .session
        case 7 * 86_400: return .weekly
        default: return .custom(limit.label.map { "Токены · \($0)" } ?? "Токены")
        }
    }

    /// Единицы окна у Z.AI: 1 — дни, 3 — часы, 5 — минуты, 6 — недели.
    private static let units: [Int: (seconds: TimeInterval, name: String)] = [
        1: (86_400, "дн"), 3: (3600, "ч"), 5: (60, "мин"), 6: (7 * 86_400, "нед"),
    ]

    private static func limit(from raw: Any, now: Date) -> Limit? {
        guard let entry = raw as? [String: Any],
              let type = entry["type"] as? String, ["TOKENS_LIMIT", "CREDIT_LIMIT", "TIME_LIMIT"].contains(type),
              let unit = integer(entry["unit"]), let number = integer(entry["number"]),
              var percent = (entry["percentage"] as? NSNumber)?.doubleValue, percent.isFinite
        else { return nil }
        let isTools = type == "TIME_LIMIT"
        let usage = integer(entry["usage"]).flatMap { $0 > 0 ? $0 : nil }
        let remaining = integer(entry["remaining"])

        // Счётчики точнее округлённого percentage.
        if let usage {
            let current = integer(entry["currentValue"])
            var used: Int?
            if let remaining {
                used = max(usage - remaining, current ?? usage - remaining)
            } else if let current {
                used = current
            }
            if let used { percent = Double(min(usage, max(0, used))) / Double(usage) * 100 }
        }

        var duration: TimeInterval?
        var label: String?
        if isTools, unit == 5, number == 1 {
            // Так Z.AI помечает месячный лимит MCP-инструментов.
            duration = 30 * 86_400
        } else if number > 0, number <= 10_000, let known = units[unit] {
            duration = Double(number) * known.seconds
            label = "\(number) \(known.name)"
        }

        var resetsAt = integer(entry["nextResetTime"]).map { Date(timeIntervalSince1970: Double($0) / 1000) }
        // Сброс пятичасового окна не может быть дальше пяти часов — такое время не показываем.
        if !isTools, duration == 5 * 3600, let reset = resetsAt, reset > now + 5 * 3600 + 60 { resetsAt = nil }

        let tools = (entry["usageDetails"] as? [[String: Any]] ?? []).prefix(20).compactMap { item -> UsageDetail? in
            guard let name = item["modelCode"] as? String, isDisplayable(name), let used = integer(item["usage"]) else { return nil }
            return UsageDetail(label: name, value: String(used))
        }
        return Limit(
            isTools: isTools, isCredits: type == "CREDIT_LIMIT", usage: usage, remaining: usage == nil ? nil : remaining,
            tools: isTools ? tools : [], percent: percent, duration: duration, label: label, resetsAt: resetsAt
        )
    }

    private static func integer(_ raw: Any?) -> Int? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value == value.rounded(), abs(value) < 1e15 else { return nil }
        return Int(value)
    }
}

// MARK: - Пиковое время

/// Пик Z.AI — будни 06:00–10:00 UTC (14:00–18:00 по Пекину), выходные целиком
/// вне пика. В пик квота расходуется быстрее: на кредитных тарифах 1× против 0,5×.
/// Сервер этого не сообщает — считается по часам, как в CodexBar.
nonisolated struct ZaiPeak: Equatable, Sendable {
    let isPeak: Bool
    /// Когда пик закончится или начнётся следующий.
    let changesAt: Date
}

nonisolated extension ZaiPeak {
    init(now: Date = .now) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // Суббота и воскресенье по UTC — не зависит от региона системы.
        func isWorkday(_ date: Date) -> Bool { ![1, 7].contains(calendar.component(.weekday, from: date)) }
        let day = calendar.startOfDay(for: now)
        let start = day + 6 * 3600
        let end = day + 10 * 3600

        if isWorkday(now), now >= start, now < end {
            self.init(isPeak: true, changesAt: end)
            return
        }
        var next = now < start ? start : start + 86_400
        while !isWorkday(next) { next += 86_400 }
        self.init(isPeak: false, changesAt: next)
    }

    func detail(usesCredits: Bool, now: Date = .now) -> UsageDetail {
        let rate = usesCredits ? (isPeak ? " · 1×" : " · 0,5×") : ""
        let countdown = Formatting.countdown(to: changesAt, now: now)
        return UsageDetail(
            label: "Тариф списания",
            value: (isPeak ? "Пик" : "Вне пика") + rate,
            note: isPeak ? "вне пика через \(countdown)" : "пик через \(countdown)"
        )
    }
}

// MARK: - Ключ

/// Где лежит секрет. Настоящее хранилище — Связка ключей, в тестах — память.
nonisolated protocol SecretBackend: Sendable {
    /// Есть ли запись — без чтения самого секрета и без запроса доступа.
    func exists() -> Bool
    func read() throws -> String?
    /// nil удаляет запись.
    func write(_ value: String?) throws
}

nonisolated struct KeychainSecret: SecretBackend {
    struct Failure: Error, Equatable {
        let status: OSStatus

        /// Пользователь отклонил запрос доступа или Связка ключей заблокирована.
        var isDenied: Bool {
            [errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed].contains(status)
        }
    }

    var service = "com.kotov.northy"
    let account: String

    private var query: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }

    func exists() -> Bool {
        var query = query
        query[kSecReturnAttributes] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    func read() throws -> String? {
        var query = query
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw Failure(status: status) }
        return String(data: data, encoding: .utf8)
    }

    func write(_ value: String?) throws {
        let deleted = SecItemDelete(query as CFDictionary)
        guard deleted == errSecSuccess || deleted == errSecItemNotFound else { throw Failure(status: deleted) }
        guard let value else { return }
        var attributes = query
        attributes[kSecValueData] = Data(value.utf8)
        attributes[kSecAttrLabel] = "Northy — API-ключ Z.AI"
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure(status: status) }
    }
}

/// API-ключ Z.AI: хранится в Связке ключей, в памяти — только после первого
/// запроса лимитов. В UserDefaults, логи и файлы приложения не попадает.
@MainActor
@Observable
final class ZaiKeyStore {
    enum KeyError: LocalizedError, Equatable {
        case invalid
        case storage

        var errorDescription: String? {
            switch self {
            case .invalid: "Это не похоже на ключ: в нём не должно быть пробелов и переносов строк"
            case .storage: "Не удалось записать ключ в Связку ключей"
            }
        }
    }

    private(set) var hasKey: Bool
    @ObservationIgnored private var cached: String?
    @ObservationIgnored private let backend: any SecretBackend

    init(backend: any SecretBackend = KeychainSecret(account: "zai-api-key")) {
        self.backend = backend
        hasKey = backend.exists()
    }

    /// Пустая строка удаляет ключ.
    func save(_ raw: String) throws {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = key.unicodeScalars.allSatisfy { $0.isASCII && $0.value > 0x20 && $0.value < 0x7F }
        guard key.count <= 512, allowed else { throw KeyError.invalid }
        do {
            try backend.write(key.isEmpty ? nil : key)
        } catch {
            throw KeyError.storage
        }
        cached = key.isEmpty ? nil : key
        hasKey = !key.isEmpty
    }

    /// Чтение из Связки ключей может показать запрос доступа — поэтому не на главном потоке.
    func key() async throws -> String? {
        if let cached { return cached }
        guard hasKey else { return nil }
        let backend = backend
        cached = try await Task.detached(priority: .utility) { try backend.read() }.value
        return cached
    }
}

/// Источник для LimitsStore: один запрос к Z.AI с ключом пользователя.
final class ZaiLimitsSource: LimitsSource {
    /// Переадресацию не выполняем: ключ не должен уйти на другой адрес.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        nonisolated func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest
        ) async -> URLRequest? { nil }
    }

    private let keys: ZaiKeyStore
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }()

    init(keys: ZaiKeyStore) {
        self.keys = keys
    }

    func fetch() async throws -> UsageSnapshot {
        let stored: String?
        do {
            stored = try await keys.key()
        } catch let failure as KeychainSecret.Failure where failure.isDenied {
            throw ZaiWeb.FetchError.keychainDenied
        }
        guard let key = stored else { throw ZaiWeb.FetchError.noKey }

        // Лимиты и оба графика запрашиваются одновременно; графики необязательны.
        async let hourly = series("Токены по часам", key: key, daysBack: 1)
        async let daily = series("Токены по дням", key: key, daysBack: 30)

        let (data, response) = try await session.data(for: ZaiWeb.request(apiKey: key))
        guard let http = response as? HTTPURLResponse else { throw ZaiWeb.FetchError.invalidResponse }
        guard http.statusCode == 200 else { throw ZaiWeb.error(forStatus: http.statusCode) }
        var snapshot = try ZaiWeb.parseQuota(data)
        snapshot.series = await [hourly, daily].compactMap { $0 }
        return snapshot
    }

    private func series(_ title: String, key: String, daysBack: Int) async -> UsageSeries? {
        guard let (data, response) = try? await session.data(for: ZaiWeb.modelUsageRequest(apiKey: key, daysBack: daysBack)),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 2_000_000
        else { return nil }
        return ZaiWeb.parseModelUsage(data, title: title)
    }
}
