import Foundation

/// Сессии Claude Code за последние сутки по локальным логам: проект (папка
/// cwd), модель последнего ответа, когда был последний ответ, расход за сегодня.
nonisolated struct ClaudeSession: Equatable, Identifiable, Sendable {
    let id: String
    let project: String
    let model: String
    let lastActivity: Date
    let todayTokens: Int
    let todayCost: Double

    /// Ответ был в последние 5 минут — сессия, скорее всего, работает прямо сейчас.
    func isActive(now: Date = .now) -> Bool {
        now.timeIntervalSince(lastActivity) < 5 * 60
    }
}

nonisolated enum ClaudeSessions {
    static let window: TimeInterval = 24 * 3600

    static func make(rows: [TokenUsageScanner.Row], now: Date = .now, calendar: Calendar = .current) -> [ClaudeSession] {
        let todayStart = calendar.startOfDay(for: now)
        let recent = rows.filter { $0.sessionID != nil && $0.timestamp <= now && now.timeIntervalSince($0.timestamp) <= window }
        let bySession = Dictionary(grouping: recent) { $0.sessionID ?? "" }
        return bySession.compactMap { id, rows -> ClaudeSession? in
            guard let last = rows.max(by: { $0.timestamp < $1.timestamp }) else { return nil }
            let today = rows.filter { $0.timestamp >= todayStart }
            let folder = rows.sorted { $0.timestamp > $1.timestamp }.lazy.compactMap(\.project).first
            return ClaudeSession(
                id: id,
                project: folder.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Без папки",
                model: last.model,
                lastActivity: last.timestamp,
                todayTokens: today.reduce(0) { $0 + $1.tokens },
                todayCost: today.reduce(0) { $0 + ($1.cost ?? 0) }
            )
        }
        .sorted { $0.lastActivity > $1.lastActivity }
    }
}
