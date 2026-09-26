import Foundation
import Testing
@testable import Northy

@MainActor
/// Лимиты подписки: модель, подача и стор — без сети, на подменённом источнике.
struct ClaudeUsageTests {

    private struct FakeSource: LimitsSource {
        var result: Result<UsageSnapshot, Error>
        let calls: Counter
        func fetch() async throws -> UsageSnapshot {
            calls.value += 1
            return try result.get()
        }
    }

    @MainActor final class Counter { var value = 0 }

    private struct Failure: LocalizedError {
        var errorDescription: String? { "нет сети" }
    }

    private func snapshot(session: Double?, weekly: Double?) -> UsageSnapshot {
        var windows: [UsageWindow] = []
        if let session { windows.append(UsageWindow(kind: .session, percent: session, resetsAt: nil)) }
        if let weekly { windows.append(UsageWindow(kind: .weekly, percent: weekly, resetsAt: nil)) }
        return UsageSnapshot(windows: windows, fetchedAt: .now)
    }

    @Test func headlineIsSessionThenWeekly() {
        #expect(snapshot(session: 37, weekly: 80).headline?.kind == .session)
        #expect(snapshot(session: nil, weekly: 80).headline?.kind == .weekly)
        #expect(snapshot(session: nil, weekly: nil).headline == nil)
    }

    @Test func percentIsClamped() {
        #expect(UsageWindow(kind: .session, percent: 140, resetsAt: nil).percent == 100)
        #expect(UsageWindow(kind: .session, percent: -3, resetsAt: nil).percent == 0)
    }

    /// Строка меню: остаток, а не использовано; только 5 ч и общая неделя.
    @Test func statusBarShowsRemainingForSessionAndWeek() {
        let full = UsageSnapshot(windows: [
            UsageWindow(kind: .session, percent: 42, resetsAt: nil),
            UsageWindow(kind: .weekly, percent: 78.4, resetsAt: nil),
            UsageWindow(kind: .model("Fable"), percent: 90, resetsAt: nil),
        ], fetchedAt: .now)
        #expect(full.statusBarLines == ["5ч 58%", "7д 22%"], "две строки друг под другом, Fable не выводится")
        #expect(snapshot(session: nil, weekly: 10).statusBarLines == ["7д 90%"])
        #expect(snapshot(session: nil, weekly: nil).statusBarLines.isEmpty)
    }

    @Test func levels() {
        #expect(UsageLevel(percent: 10) == .normal)
        #expect(UsageLevel(percent: 70) == .elevated)
        #expect(UsageLevel(percent: 90) == .critical)
    }

    @Test func countdown() {
        let now = Date(timeIntervalSince1970: 0)
        #expect(Formatting.countdown(to: now + 30, now: now) == "меньше минуты")
        #expect(Formatting.countdown(to: now + 14 * 60, now: now) == "14 мин")
        #expect(Formatting.countdown(to: now + 2 * 3600 + 14 * 60, now: now) == "2 ч 14 мин")
        #expect(Formatting.countdown(to: now + 3 * 86_400 + 4 * 3600, now: now) == "3 дн 4 ч")
        #expect(Formatting.countdown(to: now - 5, now: now) == "меньше минуты")
    }

    @Test func refreshStoresSnapshot() async {
        let calls = Counter()
        let store = LimitsStore(source: FakeSource(result: .success(snapshot(session: 42, weekly: 10)), calls: calls))
        await store.refresh()
        #expect(store.snapshot?.headline?.percent == 42)
        #expect(store.errorMessage == nil)
        #expect(calls.value == 1)
    }

    @Test func refreshIsThrottled() async {
        let calls = Counter()
        let store = LimitsStore(source: FakeSource(result: .success(snapshot(session: 1, weekly: nil)), calls: calls), minInterval: 60)
        await store.refresh()
        await store.refresh()
        #expect(calls.value == 1, "повторное открытие панели не дёргает источник")
        await store.refresh(force: true)
        #expect(calls.value == 2)
    }

    @Test func failureKeepsLastSnapshot() async {
        let calls = Counter()
        let store = LimitsStore(source: FakeSource(result: .success(snapshot(session: 5, weekly: nil)), calls: calls), minInterval: 0)
        await store.refresh()
        store.source = FakeSource(result: .failure(Failure()), calls: calls)
        await store.refresh()
        #expect(store.snapshot?.headline?.percent == 5, "последние известные данные не теряются")
        #expect(store.errorMessage == "нет сети")
    }
}
