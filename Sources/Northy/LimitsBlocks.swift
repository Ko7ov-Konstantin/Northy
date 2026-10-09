import CoreGraphics
import Foundation

/// Источник лимитов: подписка Claude или GLM Coding Plan (Z.AI).
nonisolated enum LimitsProvider: String, CaseIterable, Sendable {
    case claude, glm

    var title: String {
        switch self {
        case .claude: "Claude"
        case .glm: "GLM"
        }
    }

    /// Какие источники сейчас показываются: Claude — пока его блок не скрыт, GLM — когда задан ключ и блок не скрыт.
    static func available(blocks: [LimitsBlock], hasGLMKey: Bool) -> [LimitsProvider] {
        var result: [LimitsProvider] = []
        if blocks.contains(.claudeLimits) { result.append(.claude) }
        if hasGLMKey, blocks.contains(.glmLimits) { result.append(.glm) }
        return result
    }

    /// Выбранная вкладка меню; если её источник скрыт — первый доступный.
    static func resolve(_ preferred: LimitsProvider, available: [LimitsProvider]) -> LimitsProvider? {
        available.contains(preferred) ? preferred : available.first
    }
}

/// Блок вкладки «Лимиты». Пользователь сам решает, какие блоки видны и в каком порядке.
nonisolated enum LimitsBlock: String, CaseIterable, Identifiable, Sendable {
    case claudeLimits, glmLimits
    case claudeCost, claudeSessions, claudeDailyCost, claudePlanHistory
    case glmDetails, glmHourly, glmDaily

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claudeLimits: "Лимиты Claude"
        case .glmLimits: "Лимиты GLM"
        case .claudeCost: "Стоимость Claude Code"
        case .claudeSessions: "Сессии Claude Code"
        case .claudeDailyCost: "Стоимость по дням"
        case .claudePlanHistory: "Использование плана"
        case .glmDetails: "Детали квоты GLM"
        case .glmHourly: "Токены GLM по часам"
        case .glmDaily: "Токены GLM по дням"
        }
    }

    var icon: String {
        switch self {
        case .claudeLimits, .glmLimits: "gauge.with.dots.needle.50percent"
        case .claudeCost: "dollarsign.circle"
        case .claudeSessions: "terminal"
        case .claudeDailyCost: "chart.bar"
        case .claudePlanHistory: "chart.bar.xaxis"
        case .glmDetails: "list.bullet.rectangle"
        case .glmHourly, .glmDaily: "chart.bar"
        }
    }

    var provider: LimitsProvider {
        switch self {
        case .claudeLimits, .claudeCost, .claudeSessions, .claudeDailyCost, .claudePlanHistory: .claude
        case .glmLimits, .glmDetails, .glmHourly, .glmDaily: .glm
        }
    }

    /// Небольшие графики встают по два в ряд.
    var isHalfWidth: Bool {
        switch self {
        case .claudeDailyCost, .claudePlanHistory, .glmHourly, .glmDaily: true
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
