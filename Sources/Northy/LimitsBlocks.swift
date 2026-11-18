import CoreGraphics
import Foundation
import SwiftUI

/// Источник лимитов: подписка Claude, GLM Coding Plan (Z.AI) или Gemini по входу Google из Antigravity.
nonisolated enum LimitsProvider: String, CaseIterable, Sendable {
    case claude, glm, gemini

    var title: String {
        switch self {
        case .claude: "Claude"
        case .glm: "GLM"
        case .gemini: "Gemini"
        }
    }

    /// Заголовок карточки в меню и раздела во вкладке «Лимиты».
    var fullTitle: String {
        switch self {
        case .claude: "Claude"
        case .glm: "GLM · Z.AI"
        case .gemini: "Gemini · Antigravity"
        }
    }

    /// Пункт меню «Дашборд использования»; nil — пункта у источника нет.
    var dashboardURL: URL? {
        switch self {
        case .claude: URL(string: "https://claude.ai/settings/usage")
        case .glm: ZaiWeb.dashboardURL
        case .gemini: nil
        }
    }

    /// Пункт меню «Страница статуса»; nil — публичной страницы у источника нет.
    var statusPageURL: URL? {
        switch self {
        case .claude: StatusPage.pageURL
        case .glm: nil
        case .gemini: StatusPage.geminiPageURL
        }
    }

    /// Цвет значков блоков источника в режиме правки вкладки «Лимиты».
    @MainActor var tint: Color {
        switch self {
        case .claude: Theme.sky
        case .glm: Theme.mint
        case .gemini: Theme.violet
        }
    }

    /// Файл истории замеров для графика «Использование плана».
    var historyFileName: String { "\(rawValue)-usage-history.json" }

    /// Какие источники сейчас показываются: включённые в настройках; GLM нужен ещё ключ,
    /// Gemini — вход Google из Antigravity. Блоки вкладки «Лимиты» на это не влияют.
    static func available(enabled: Set<LimitsProvider>, hasGLMKey: Bool, hasGeminiLogin: Bool) -> [LimitsProvider] {
        allCases.filter { provider in
            guard enabled.contains(provider) else { return false }
            switch provider {
            case .claude: return true
            case .glm: return hasGLMKey
            case .gemini: return hasGeminiLogin
            }
        }
    }

    /// Выбранная вкладка меню; если её источник скрыт — первый доступный.
    static func resolve(_ preferred: LimitsProvider, available: [LimitsProvider]) -> LimitsProvider? {
        available.contains(preferred) ? preferred : available.first
    }
}

/// Блок вкладки «Лимиты». Пользователь сам решает, какие блоки видны и в каком порядке.
nonisolated enum LimitsBlock: String, CaseIterable, Identifiable, Sendable {
    case claudeLimits, glmLimits, geminiLimits
    case claudeCost, claudeSessions, claudeDailyCost, claudePlanHistory
    case glmDetails, glmHourly, glmDaily, glmPlanHistory
    case geminiDetails, geminiPlanHistory

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claudeLimits: "Лимиты Claude"
        case .glmLimits: "Лимиты GLM"
        case .geminiLimits: "Лимиты Gemini"
        case .claudeCost: "Стоимость Claude Code"
        case .claudeSessions: "Сессии Claude Code"
        case .claudeDailyCost: "Стоимость по дням"
        case .claudePlanHistory: "Использование плана"
        case .glmDetails: "Детали квоты GLM"
        case .glmHourly: "Токены GLM по часам"
        case .glmDaily: "Токены GLM по дням"
        case .glmPlanHistory: "Использование плана GLM"
        case .geminiDetails: "Детали квоты Gemini"
        case .geminiPlanHistory: "Использование плана Gemini"
        }
    }

    var icon: String {
        switch self {
        case .claudeLimits, .glmLimits, .geminiLimits: "gauge.with.dots.needle.50percent"
        case .claudeCost: "dollarsign.circle"
        case .claudeSessions: "terminal"
        case .claudeDailyCost: "chart.bar"
        case .claudePlanHistory, .glmPlanHistory, .geminiPlanHistory: "chart.bar.xaxis"
        case .glmDetails, .geminiDetails: "list.bullet.rectangle"
        case .glmHourly, .glmDaily: "chart.bar"
        }
    }

    var provider: LimitsProvider {
        switch self {
        case .claudeLimits, .claudeCost, .claudeSessions, .claudeDailyCost, .claudePlanHistory: .claude
        case .glmLimits, .glmDetails, .glmHourly, .glmDaily, .glmPlanHistory: .glm
        case .geminiLimits, .geminiDetails, .geminiPlanHistory: .gemini
        }
    }

    /// Небольшие графики встают по два в ряд.
    var isHalfWidth: Bool {
        switch self {
        case .claudeDailyCost, .claudePlanHistory, .glmHourly, .glmDaily, .glmPlanHistory, .geminiPlanHistory: true
        default: false
        }
    }

    /// Блоки, которым нужны локальные логи Claude Code.
    var needsTokenLogs: Bool {
        self == .claudeCost || self == .claudeSessions || self == .claudeDailyCost
    }

    /// Сохранённый список: неизвестные и повторные значения отбрасываются.
    static func sanitized(_ raw: [String]) -> [LimitsBlock] {
        var seen = Set<LimitsBlock>()
        return raw.compactMap(LimitsBlock.init(rawValue:)).filter { seen.insert($0).inserted }
    }

    /// Блок лимитов источника, который включают в настройках.
    static func limits(of provider: LimitsProvider) -> LimitsBlock {
        switch provider {
        case .claude: .claudeLimits
        case .glm: .glmLimits
        case .gemini: .geminiLimits
        }
    }

    /// Куда встаёт возвращённый блок лимитов: в начало, в порядке Claude, GLM, Gemini.
    static func limitsIndex(for block: LimitsBlock, in blocks: [LimitsBlock]) -> Int {
        let order = LimitsProvider.allCases.map(limits(of:))
        let earlier = order.prefix { $0 != block }
        return blocks.prefix { earlier.contains($0) }.count
    }

    /// Строки вкладки: два соседних небольших блока делят строку пополам.
    static func rows(_ blocks: [LimitsBlock]) -> [[LimitsBlock]] {
        var rows: [[LimitsBlock]] = []
        for block in blocks {
            if block.isHalfWidth, let last = rows.last, last.count == 1, last[0].isHalfWidth {
                rows[rows.count - 1].append(block)
            } else {
                rows.append([block])
            }
        }
        return rows
    }

    /// Добавляет блок или переносит уже видимый; index — место в списке до переноса.
    static func placing(_ block: LimitsBlock, at index: Int, in blocks: [LimitsBlock]) -> [LimitsBlock] {
        var result = blocks
        var target = min(max(0, index), blocks.count)
        if let current = result.firstIndex(of: block) {
            result.remove(at: current)
            if current < target { target -= 1 }
        }
        result.insert(block, at: target)
        return result
    }

    /// Куда встанет блок, отпущенный в точке: перед первым блоком, который ниже
    /// точки или стоит в той же строке правее неё.
    static func insertionIndex(frames: [CGRect], point: CGPoint) -> Int {
        for (index, frame) in frames.enumerated() {
            if point.y < frame.minY { return index }
            if point.y <= frame.maxY, point.x < frame.midX { return index }
        }
        return frames.count
    }
}
