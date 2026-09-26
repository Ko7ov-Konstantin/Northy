import Foundation
import Testing
@testable import Northy

@MainActor
/// Темп расхода, план подписки и оценка сеансов — формулы CodexBar
/// (UsagePace, ClaudePlan, SessionEquivalentForecast), проверенные на числах.
struct UsagePaceTests {

    private let now = Date(timeIntervalSince1970: 1_000_000)

    // MARK: темп

    @Test func reserveWhenBehindLinearPace() throws {
        // Прошла половина 5-часового окна, использовано 29% — ожидалось 50%.
        let window = UsageWindow(kind: .session, percent: 29, resetsAt: now + 2.5 * 3600)
        let pace = try #require(UsagePace.make(for: window, now: now))
        #expect(Int(pace.deltaPercent.rounded()) == -21)
        #expect(pace.summary == "21% в резерве")
        #expect(pace.willLastToReset)
        #expect(pace.outlook(now: now) == "Действует до сброса")
    }

    @Test func deficitWithRunOutEstimate() throws {
        // Прошёл 1 час из 5, использовано 50% — при той же скорости кончится через час.
        let window = UsageWindow(kind: .session, percent: 50, resetsAt: now + 4 * 3600)
        let pace = try #require(UsagePace.make(for: window, now: now))
        #expect(pace.summary == "30% в дефиците")
        #expect(!pace.willLastToReset)
        #expect(pace.outlook(now: now) == "Закончится через 1 ч")
    }

    @Test func onPaceWithinTwoPercent() throws {
        let window = UsageWindow(kind: .weekly, percent: 51, resetsAt: now + 3.5 * 86_400)
        #expect(try #require(UsagePace.make(for: window, now: now)).summary == "В темпе")
    }

    @Test func noPaceWithoutResetOrOutsideWindow() {
        #expect(UsagePace.make(for: UsageWindow(kind: .session, percent: 10, resetsAt: nil), now: now) == nil)
        #expect(UsagePace.make(for: UsageWindow(kind: .session, percent: 10, resetsAt: now - 1), now: now) == nil)
        #expect(UsagePace.make(for: UsageWindow(kind: .session, percent: 10, resetsAt: now + 6 * 3600), now: now) == nil)
    }

    @Test func unusedWindowLastsToReset() throws {
        let window = UsageWindow(kind: .model("Fable"), percent: 0, resetsAt: now + 86_400)
        let pace = try #require(UsagePace.make(for: window, now: now))
        #expect(pace.summary == "86% в резерве")
        #expect(pace.willLastToReset)
    }

    // MARK: план подписки из /api/account

    @Test func planFromRateLimitTier() {
        func account(_ tier: String?, billing: String? = nil, seat: String? = nil, org: String = "o1") -> Data {
            let tierJSON = tier.map { "\"\($0)\"" } ?? "null"
            let billingJSON = billing.map { "\"\($0)\"" } ?? "null"
            let seatJSON = seat.map { "\"\($0)\"" } ?? "null"
            return Data("""
            {"email_address":"a@b.c","memberships":[{"seat_tier":\(seatJSON),
             "organization":{"uuid":"\(org)","rate_limit_tier":\(tierJSON),"billing_type":\(billingJSON)}}]}
            """.utf8)
        }
        #expect(ClaudeWeb.planLabel(fromAccount: account("default_claude_max_20x"), organizationID: "o1") == "Max 20x")
        #expect(ClaudeWeb.planLabel(fromAccount: account("default_claude_max_5x"), organizationID: nil) == "Max 5x")
        #expect(ClaudeWeb.planLabel(fromAccount: account("claude_max"), organizationID: nil) == "Max")
        #expect(ClaudeWeb.planLabel(fromAccount: account("default_claude_pro"), organizationID: nil) == "Pro")
        #expect(ClaudeWeb.planLabel(fromAccount: account("default_claude_ai", billing: "stripe_subscription"), organizationID: nil) == "Pro")
        #expect(ClaudeWeb.planLabel(fromAccount: account("team", seat: "team_tier_1"), organizationID: nil) == "Team Premium")
        #expect(ClaudeWeb.planLabel(fromAccount: account(nil), organizationID: nil) == nil)
        #expect(ClaudeWeb.planLabel(fromAccount: Data("мусор".utf8), organizationID: nil) == nil)
    }

    // MARK: оценка сеансов по истории

    private func sample(_ t: TimeInterval, session: Double, sessionReset: TimeInterval, weekly: Double) -> UsageHistory.Sample {
        UsageHistory.Sample(
            capturedAt: now + t,
            sessionPercent: session,
            sessionResetsAt: now + sessionReset,
            weeklyPercent: weekly,
            weeklyResetsAt: now + 5 * 86_400
        )
    }

    @Test func forecastNeedsThreeCompletedWindows() {
        // Каждое окно: сессия 0→50%, неделя +5% — полное окно стоит 10% недели.
        var samples: [UsageHistory.Sample] = []
        for index in 0..<3 {
            let base = TimeInterval(index) * 5 * 3600
            samples.append(sample(base - 20 * 3600 + 60, session: 0, sessionReset: base - 15 * 3600, weekly: Double(20 + index * 5)))
            samples.append(sample(base - 16 * 3600, session: 50, sessionReset: base - 15 * 3600, weekly: Double(25 + index * 5)))
        }
        let session = UsageWindow(kind: .session, percent: 10, resetsAt: now + 3 * 3600)
        let weekly = UsageWindow(kind: .weekly, percent: 40, resetsAt: now + 20 * 3600)

        let forecast = UsageHistory.forecast(samples: samples, session: session, weekly: weekly, now: now)
        #expect(forecast?.estimatedSessions == 6, "осталось 60% недели по 10% за полное окно")
        #expect(forecast?.windowsUntilReset == 4, "20 ч до сброса недели — 4 полных окна по 5 ч")
        #expect(UsageHistory.forecast(samples: Array(samples.prefix(4)), session: session, weekly: weekly, now: now) == nil)
    }

    /// График «Использование плана»: один столбик на окно — пик расхода в нём.
    @Test func peaksGroupByWindow() {
        let samples = [
            sample(0, session: 5, sessionReset: 3600, weekly: 10),
            sample(600, session: 40, sessionReset: 3600, weekly: 14),
            sample(1200, session: 30, sessionReset: 3600, weekly: 15),
            sample(20_000, session: 7, sessionReset: 21_600, weekly: 16),
        ]
        let session = UsageHistory.peaks(samples, series: .session)
        #expect(session.map(\.percent) == [40, 7])
        #expect(session.first?.date == now + 600, "дата — момент пика")

        let weekly = UsageHistory.peaks(samples, series: .weekly)
        #expect(weekly.map(\.percent) == [16], "все замеры в одной неделе")
    }

    @Test func historyAppendsDedupsAndCaps() {
        var samples: [UsageHistory.Sample] = []
        let s = sample(0, session: 1, sessionReset: 3600, weekly: 2)
        samples = UsageHistory.appending(s, to: samples, limit: 3)
        samples = UsageHistory.appending(s, to: samples, limit: 3)
        #expect(samples.count == 1, "одинаковый замер не дублируется")
        for index in 1...5 {
            samples = UsageHistory.appending(sample(TimeInterval(index * 60), session: Double(index), sessionReset: 3600, weekly: 2), to: samples, limit: 3)
        }
        #expect(samples.count == 3)
        #expect(samples.last?.sessionPercent == 5)
    }
}
