import AppKit

/// Состояние сервисов Claude с публичной страницы status.claude.com
/// (Statuspage API, без авторизации) — для подменю «Страница статуса».
nonisolated enum StatusPage {

    static let pageURL = URL(string: "https://status.claude.com")!
    static let componentsURL = URL(string: "https://status.claude.com/api/v2/components.json")!
    /// Статус Gemini — лента инцидентов Google Workspace по идентификатору продукта, как у CodexBar.
    static let geminiProductID = "npdyhgECDJ6tB66MxXyo"
    static let geminiPageURL = URL(string: "https://www.google.com/appsstatus/dashboard/products/\(geminiProductID)/history")!
    static let googleIncidentsURL = URL(string: "https://www.google.com/appsstatus/dashboard/incidents.json")!

    enum Status: String, Sendable {
        case operational
        case degradedPerformance = "degraded_performance"
        case partialOutage = "partial_outage"
        case majorOutage = "major_outage"
        case underMaintenance = "under_maintenance"
        case unknown

        var title: String {
            switch self {
            case .operational: "Работает"
            case .degradedPerformance: "Замедление"
            case .partialOutage: "Частичный сбой"
            case .majorOutage: "Серьёзный сбой"
            case .underMaintenance: "Обслуживание"
            case .unknown: "Неизвестно"
            }
        }

        var color: NSColor {
            switch self {
            case .operational: .systemGreen
            case .degradedPerformance: .systemYellow
            case .partialOutage: .systemOrange
            case .majorOutage: .systemRed
            case .underMaintenance: .systemBlue
            case .unknown: .systemGray
            }
        }
    }

    struct Component: Equatable, Sendable {
        let name: String
        let status: Status
    }

    private struct Response: Decodable {
        struct Item: Decodable {
            let name: String
            let status: String
            let group: Bool?
            let group_id: String?
            let only_show_if_degraded: Bool?
        }
        let components: [Item]
    }

    /// Верхний уровень без групп; «показывать только при сбое» скрыт, пока всё работает.
    static func parse(_ data: Data) throws -> [Component] {
        let response = try JSONDecoder().decode(Response.self, from: data)
        return response.components.compactMap { item in
            guard item.group != true, item.group_id == nil else { return nil }
            let status = Status(rawValue: item.status) ?? .unknown
            if item.only_show_if_degraded == true, status == .operational { return nil }
            return Component(name: item.name, status: status)
        }
    }

    /// Строка свежести вверху подменю; при ошибке прошлые статусы остаются, но помечены.
    static func freshness(updatedAt: Date?, isLoading: Bool, failed: Bool, now: Date = .now) -> String {
        guard let updatedAt else {
            if isLoading { return "Обновляется…" }
            return failed ? "Не удалось загрузить статус" : "Нет данных"
        }
        let age = Formatting.relative(updatedAt, now: now)
        if isLoading { return "Обновляется… · данные \(age)" }
        if failed { return "Не удалось обновить · данные \(age)" }
        return "Обновлено \(age)"
    }

    private struct Incident: Decodable {
        struct Product: Decodable {
            let id: String
        }
        struct Update: Decodable {
            let status: String?
        }
        let end: String?
        let status_impact: String?
        let severity: String?
        let affected_products: [Product]?
        let currently_affected_products: [Product]?
        let most_recent_update: Update?

        var status: Status {
            switch (most_recent_update?.status ?? status_impact)?.uppercased() {
            case "AVAILABLE": return .operational
            case "SERVICE_INFORMATION": return .degradedPerformance
            case "SERVICE_DISRUPTION": return .partialOutage
            case "SERVICE_OUTAGE": return .majorOutage
            case "SERVICE_MAINTENANCE", "SCHEDULED_MAINTENANCE": return .underMaintenance
            default: break
            }
            switch severity?.lowercased() {
            case "medium": return .partialOutage
            case "high": return .majorOutage
            default: return .degradedPerformance
            }
        }
    }

    /// Чем тяжелее сбой, тем больше число: из открытых инцидентов берётся самый тяжёлый.
    private static let severityOrder: [Status] = [.operational, .unknown, .underMaintenance, .degradedPerformance, .partialOutage, .majorOutage]

    /// Одна строка «Gemini»: открытых инцидентов продукта нет — работает.
    static func parseGoogleIncidents(_ data: Data) throws -> [Component] {
        let incidents = try JSONDecoder().decode([Incident].self, from: data)
        let open = incidents.filter { incident in
            incident.end == nil && (incident.currently_affected_products ?? incident.affected_products ?? []).contains { $0.id == geminiProductID }
        }
        let worst = open.map(\.status).max { (severityOrder.firstIndex(of: $0) ?? 0) < (severityOrder.firstIndex(of: $1) ?? 0) }
        return [Component(name: "Gemini", status: worst ?? .operational)]
    }

    /// Статусы источника; у источника без публичной страницы список пуст.
    static func fetch(for provider: LimitsProvider) async throws -> [Component] {
        let url: URL
        switch provider {
        case .claude: url = componentsURL
        case .gemini: url = googleIncidentsURL
        case .glm, .codex: return []
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.httpShouldHandleCookies = false
        let (data, _) = try await URLSession(configuration: .ephemeral).data(for: request)
        return provider == .claude ? try parse(data) : try parseGoogleIncidents(data)
    }
}
