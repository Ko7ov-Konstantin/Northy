import AppKit

/// Состояние сервисов Claude с публичной страницы status.claude.com
/// (Statuspage API, без авторизации) — для подменю «Страница статуса».
nonisolated enum StatusPage {

    static let pageURL = URL(string: "https://status.claude.com")!
    static let componentsURL = URL(string: "https://status.claude.com/api/v2/components.json")!

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

    static func fetch() async throws -> [Component] {
        var request = URLRequest(url: componentsURL)
        request.timeoutInterval = 10
        request.httpShouldHandleCookies = false
        let (data, _) = try await URLSession(configuration: .ephemeral).data(for: request)
        return try parse(data)
    }
}
