import Foundation

/// Лимиты подписки через веб-сессию claude.ai — повторяет веб-режим CodexBar:
/// cookie sessionKey из Safari, GET /api/organizations → GET /api/organizations/{id}/usage.
/// Ключ сессии живёт только в памяти на время запроса: не логируется, не
/// сохраняется и уходит только на https://claude.ai.
nonisolated enum ClaudeWeb {

    static let baseURL = URL(string: "https://claude.ai")!

    enum FetchError: LocalizedError, Equatable {
        case noDiskAccess
        case noSession
        case unauthorized
        case cloudflare
        case rateLimited
        case server(Int)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .noDiskAccess:
                "Нет доступа к cookies Safari. Дайте Northy «Полный доступ к диску» в настройках конфиденциальности"
            case .noSession:
                "Не найдена сессия claude.ai в Safari — войдите на claude.ai в Safari"
            case .unauthorized:
                "Сессия claude.ai истекла — зайдите на claude.ai в Safari заново"
            case .cloudflare:
                "claude.ai попросил проверку Cloudflare — откройте claude.ai в Safari и попробуйте позже"
            case .rateLimited:
                "claude.ai просит подождать — попробуйте через пару минут"
            case .server(let code):
                "claude.ai ответил ошибкой \(code)"
            case .invalidResponse:
                "Не удалось разобрать ответ claude.ai"
            }
        }
    }

    // MARK: - Сессия

    static func sessionKey(in cookies: [BinaryCookies.Cookie], now: Date = .now) -> String? {
        for cookie in cookies where cookie.name == "sessionKey" && isClaudeDomain(cookie.domain) && cookie.expires > now {
            let value = cookie.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("sk-ant-") { return value }
        }
        return nil
    }

    private static func isClaudeDomain(_ domain: String) -> Bool {
        domain == "claude.ai" || domain == ".claude.ai"
    }

    /// Cookies Safari: новый путь (контейнер) и старый. Нет доступа —
    /// значит, приложению не выдан «Полный доступ к диску».
    static func loadSafariSessionKey() throws -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            "Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies",
            "Library/Cookies/Cookies.binarycookies",
        ].map { home.appendingPathComponent($0) }

        var deniedAccess = false
        for url in candidates {
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch let error as NSError {
                if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoPermissionError {
                    deniedAccess = true
                }
                continue
            }
            if let cookies = try? BinaryCookies.parse(data), let key = sessionKey(in: cookies) {
                return key
            }
        }
        throw deniedAccess ? FetchError.noDiskAccess : FetchError.noSession
    }

    // MARK: - Запросы

    static func request(path: String, sessionKey: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.httpShouldHandleCookies = false
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    static func error(for response: HTTPURLResponse, body: Data) -> FetchError {
        switch response.statusCode {
        case 401:
            return .unauthorized
        case 403:
            let mitigated = response.value(forHTTPHeaderField: "cf-mitigated")?
                .trimmingCharacters(in: .whitespaces).lowercased() == "challenge"
            let challengePage = String(decoding: body.prefix(64 * 1024), as: UTF8.self)
                .localizedCaseInsensitiveContains("Just a moment")
            return mitigated || challengePage ? .cloudflare : .unauthorized
        case 429:
            return .rateLimited
        default:
            return .server(response.statusCode)
        }
    }

    // MARK: - Ответы

    private struct Organization: Decodable {
        let uuid: String
        let capabilities: [String]?

        var normalized: Set<String> { Set((capabilities ?? []).map { $0.lowercased() }) }
        var hasChat: Bool { normalized.contains("chat") }
        var isApiOnly: Bool { normalized == ["api"] }
    }

    /// Как в CodexBar: организация с чатом, иначе не только-API, иначе первая.
    /// В путь запроса попадает только настоящий UUID.
    static func organizationID(from data: Data) throws -> String {
        guard let organizations = try? JSONDecoder().decode([Organization].self, from: data) else {
            throw FetchError.invalidResponse
        }
        guard let selected = organizations.first(where: \.hasChat)
            ?? organizations.first(where: { !$0.isApiOnly })
            ?? organizations.first,
            UUID(uuidString: selected.uuid) != nil
        else { throw FetchError.invalidResponse }
        return selected.uuid
    }

    private struct Account: Decodable {
        struct Membership: Decodable {
            struct Organization: Decodable {
                let uuid: String?
                let rate_limit_tier: String?
                let billing_type: String?
            }
            let organization: Organization
            let seat_tier: String?
        }
        let memberships: [Membership]?
    }

    /// План из GET /api/account — как ClaudePlan в CodexBar: rate_limit_tier
    /// «…max_20x» → «Max 20x», pro → «Pro», stripe-подписка без tier → «Pro»,
    /// Team различается по seat_tier.
    static func planLabel(fromAccount data: Data, organizationID: String?) -> String? {
        guard let account = try? JSONDecoder().decode(Account.self, from: data),
              let memberships = account.memberships, !memberships.isEmpty
        else { return nil }
        let membership = memberships.first { $0.organization.uuid == organizationID } ?? memberships[0]
        let tier = (membership.organization.rate_limit_tier ?? "").lowercased()
        let words = tier.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)

        if tier.contains("max") {
            if let index = words.firstIndex(of: "max"), index + 1 < words.count,
               words[index + 1].hasSuffix("x"), Int(words[index + 1].dropLast()) != nil {
                return "Max \(words[index + 1])"
            }
            return "Max"
        }
        if tier.contains("pro") { return "Pro" }
        if tier.contains("team") {
            switch membership.seat_tier?.lowercased() {
            case "team_standard": return "Team Standard"
            case "team_tier_1": return "Team Premium"
            default: return "Team"
            }
        }
        if tier.contains("enterprise") { return "Enterprise" }
        if (membership.organization.billing_type ?? "").lowercased().contains("stripe"), tier.contains("claude") {
            return "Pro"
        }
        return nil
    }

    static func parseUsage(_ data: Data, now: Date = .now) throws -> UsageSnapshot {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FetchError.invalidResponse
        }
        let keys: [(String, UsageWindow.Kind)] = [
            ("five_hour", .session),
            ("seven_day", .weekly),
            ("seven_day_sonnet", .model("Sonnet")),
            ("seven_day_opus", .model("Opus")),
        ]
        var windows = keys.compactMap { key, kind -> UsageWindow? in
            guard let object = json[key] as? [String: Any],
                  let percent = (object["utilization"] as? NSNumber)?.doubleValue
            else { return nil }
            return UsageWindow(kind: kind, percent: percent, resetsAt: parseDate(object["resets_at"] as? String))
        }
        for window in scopedWeeklyWindows(json["limits"]) where !windows.contains(where: {
            $0.title.caseInsensitiveCompare(window.title) == .orderedSame
        }) {
            windows.append(window)
        }
        guard !windows.isEmpty else { throw FetchError.invalidResponse }
        return UsageSnapshot(windows: windows, fetchedAt: now)
    }

    /// Недельные лимиты отдельных моделей из массива limits — как в CodexBar
    /// (ClaudeScopedWeeklyLimitMapper): kind "weekly_scoped", group "weekly",
    /// имя модели — scope.model.display_name; «All models» — это общая неделя.
    private static func scopedWeeklyWindows(_ raw: Any?) -> [UsageWindow] {
        guard let limits = raw as? [[String: Any]] else { return [] }
        return limits.compactMap { entry in
            guard entry["kind"] as? String == "weekly_scoped",
                  entry["group"] as? String == "weekly",
                  let percent = (entry["percent"] as? NSNumber)?.doubleValue, percent.isFinite,
                  let model = (entry["scope"] as? [String: Any])?["model"] as? [String: Any],
                  let name = (model["display_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty
            else { return nil }
            let id = (model["id"] as? String)?.lowercased() ?? ""
            if name.lowercased() == "all models" || id == "all-models" || id.hasSuffix("-all-models") { return nil }
            return UsageWindow(kind: .model(name), percent: percent, resetsAt: parseDate(entry["resets_at"] as? String))
        }
    }

    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        // Микросекунды ("…00.123456+00:00") форматтер не всегда принимает — отбрасываем дробь.
        let trimmed = raw.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: trimmed)
    }
}

/// Источник для LimitsStore: каждый вызов заново читает сессию из Safari
/// (вход в другой аккаунт подхватывается сам), организация кэшируется.
final class ClaudeWebLimitsSource: LimitsSource {
    private var organizationID: String?
    private var plan: String?
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    func fetch() async throws -> UsageSnapshot {
        let sessionKey = try await Task.detached(priority: .utility) {
            try ClaudeWeb.loadSafariSessionKey()
        }.value

        let organization: String
        if let organizationID {
            organization = organizationID
        } else {
            let data = try await get("/api/organizations", sessionKey: sessionKey)
            organization = try ClaudeWeb.organizationID(from: data)
            organizationID = organization
        }

        do {
            let data = try await get("/api/organizations/\(organization)/usage", sessionKey: sessionKey)
            var snapshot = try ClaudeWeb.parseUsage(data)
            snapshot.plan = await planLabel(organization: organization, sessionKey: sessionKey)
            return snapshot
        } catch ClaudeWeb.FetchError.unauthorized {
            // Смена аккаунта: закэшированная организация чужая — со следующей попытки ищем заново.
            organizationID = nil
            plan = nil
            throw ClaudeWeb.FetchError.unauthorized
        }
    }

    /// План меняется редко — запрашивается один раз; ошибка тут лимиты не ломает.
    private func planLabel(organization: String, sessionKey: String) async -> String? {
        if let plan { return plan }
        guard let data = try? await get("/api/account", sessionKey: sessionKey) else { return nil }
        plan = ClaudeWeb.planLabel(fromAccount: data, organizationID: organization)
        return plan
    }

    private func get(_ path: String, sessionKey: String) async throws -> Data {
        let (data, response) = try await session.data(for: ClaudeWeb.request(path: path, sessionKey: sessionKey))
        guard let http = response as? HTTPURLResponse else { throw ClaudeWeb.FetchError.invalidResponse }
        guard http.statusCode == 200 else { throw ClaudeWeb.error(for: http, body: data) }
        return data
    }
}
