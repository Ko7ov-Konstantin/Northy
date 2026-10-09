import Foundation
import Testing
@testable import Northy

@MainActor
/// Сессии Claude Code по локальным логам: проект, последняя активность, расход за сегодня.
struct ClaudeSessionsTests {

    private let now = ISO8601DateFormatter().date(from: "2026-09-26T12:00:00Z")!
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// Токен вывода стоит $1 — стоимость строки задаётся числом токенов вывода.
    private let prices = [
        "claude-opus-5-5": TokenPricing.Rates(input: 0, output: 1_000_000),
        "claude-sonnet-5": TokenPricing.Rates(input: 0, output: 1_000_000),
    ]

    private func row(_ session: String?, _ minutesAgo: Double, tokens: Int = 100, cost: Int = 1, model: String = "claude-opus-5-5", project: String? = "/Users/me/app") -> TokenUsageScanner.Row {
        TokenUsageScanner.Row(
            key: UUID().uuidString,
            timestamp: now - minutesAgo * 60,
            model: model,
            usage: .init(input: tokens - cost, output: cost),
            sessionID: session,
            project: project
        )
    }

    @Test func groupsBySessionNewestFirst() {
        let rows = [
            row("a", 200, cost: 2),
            row("a", 3, cost: 3, model: "claude-sonnet-5"),
            row("b", 30, project: "/Users/me/northy"),
            row("c", 60 * 30, project: "/Users/me/old"),   // 30 ч назад — за пределами суток
            row(nil, 1),                                  // без сессии — не показывается
        ]
        let sessions = ClaudeSessions.make(rows: rows, now: now, calendar: calendar, prices: prices)
        #expect(sessions.map(\.id) == ["a", "b"])
        let first = sessions[0]
        #expect(first.project == "app")
        #expect(first.model == "claude-sonnet-5", "модель — последнего ответа")
        #expect(first.todayCost == 5)
        #expect(first.todayTokens == 200)
        #expect(first.lastActivity == now - 180)
        #expect(first.isActive(now: now), "ответ 3 минуты назад — сессия идёт")
        #expect(!sessions[1].isActive(now: now))
        #expect(sessions[1].project == "northy")
    }

    @Test func todayCountsOnlySinceMidnight() {
        // 13 ч назад — вчера (по UTC полночь 12 ч назад), но в пределах суток.
        let rows = [row("a", 13 * 60, tokens: 50, cost: 5), row("a", 10, tokens: 70, cost: 7)]
        let session = ClaudeSessions.make(rows: rows, now: now, calendar: calendar, prices: prices).first
        #expect(session?.todayCost == 7)
        #expect(session?.todayTokens == 70)
    }

    @Test func projectFallsBackWhenCwdMissing() {
        let sessions = ClaudeSessions.make(rows: [row("x", 1, project: nil)], now: now, calendar: calendar)
        #expect(sessions.first?.project == "Без папки")
    }

    @Test func scannerKeepsSessionAndCwd() {
        let line = #"{"type":"assistant","timestamp":"2026-09-26T10:00:00Z","sessionId":"s-1","cwd":"/Users/me/northy","requestId":"r","message":{"id":"m","model":"claude-opus-5-5","usage":{"input_tokens":10,"output_tokens":5}}}"#
        let parsed = TokenUsageScanner.parse(lines: [line]).first
        #expect(parsed?.sessionID == "s-1")
        #expect(parsed?.project == "/Users/me/northy")
    }
}
