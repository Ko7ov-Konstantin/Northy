import Foundation
import Observation

/// История замеров лимитов — для оценки «сколько ещё полных сеансов влезет
/// в недельный лимит», как SessionEquivalentForecast в CodexBar. Замер
/// пишется при каждом успешном обновлении (открытие панели или меню).
@MainActor
@Observable
final class UsageHistory {

    nonisolated struct Sample: Codable, Equatable, Sendable {
        let capturedAt: Date
        let sessionPercent: Double
        let sessionResetsAt: Date
        let weeklyPercent: Double
        let weeklyResetsAt: Date
    }

    nonisolated struct Forecast: Equatable, Sendable {
        /// Сколько полных 5-часовых сеансов ещё выдержит недельный лимит.
        let estimatedSessions: Double
        /// Сколько полных 5-часовых окон осталось до сброса недели.
        let windowsUntilReset: Int
    }

    nonisolated static let sessionDuration: TimeInterval = 5 * 3600
    nonisolated static let minimumSamples = 3
    nonisolated static let sampleLimit = 7

    private(set) var samples: [Sample]
    @ObservationIgnored private let store: JSONStore

    init(directory: URL = AppData.directory) {
        store = JSONStore(url: directory.appendingPathComponent("claude-usage-history.json"))
        samples = store.read([Sample].self) ?? []
    }

    func record(_ snapshot: UsageSnapshot) {
        guard let sample = Self.sample(from: snapshot) else { return }
        let updated = Self.appending(sample, to: samples, limit: 500)
        guard updated != samples else { return }
        samples = updated
        store.write(samples)
    }

    func flush() {
        store.flush()
    }

    func forecast(for snapshot: UsageSnapshot, now: Date = .now) -> Forecast? {
        guard let session = snapshot.windows.first(where: { $0.kind == .session }),
              let weekly = snapshot.windows.first(where: { $0.kind == .weekly })
        else { return nil }
        return Self.forecast(samples: samples, session: session, weekly: weekly, now: now)
    }

    // MARK: - Чистая логика

    nonisolated static func sample(from snapshot: UsageSnapshot) -> Sample? {
        guard let session = snapshot.windows.first(where: { $0.kind == .session }),
              let weekly = snapshot.windows.first(where: { $0.kind == .weekly }),
              let sessionResetsAt = session.resetsAt,
              let weeklyResetsAt = weekly.resetsAt
        else { return nil }
        return Sample(
            capturedAt: snapshot.fetchedAt,
            sessionPercent: session.percent,
            sessionResetsAt: sessionResetsAt,
            weeklyPercent: weekly.percent,
            weeklyResetsAt: weeklyResetsAt
        )
    }

    nonisolated enum Series: String, CaseIterable, Sendable {
        case session = "Сеанс"
        case weekly = "Недельный"
    }

    nonisolated struct Peak: Equatable, Sendable {
        let date: Date
        let percent: Double
    }

    /// Один столбик на окно (5-часовое или недельное) — пик расхода в нём,
    /// с моментом, когда пик был замерен. Как график плана у CodexBar.
    nonisolated static func peaks(_ samples: [Sample], series: Series) -> [Peak] {
        var groups: [(resetsAt: Date, peak: Peak)] = []
        for sample in samples.sorted(by: { $0.capturedAt < $1.capturedAt }) {
            let resetsAt = series == .session ? sample.sessionResetsAt : sample.weeklyResetsAt
            let percent = series == .session ? sample.sessionPercent : sample.weeklyPercent
            if let index = groups.lastIndex(where: { abs($0.resetsAt.timeIntervalSince(resetsAt)) < 120 }) {
                if percent >= groups[index].peak.percent {
                    groups[index].peak = Peak(date: sample.capturedAt, percent: percent)
                }
            } else {
                groups.append((resetsAt, Peak(date: sample.capturedAt, percent: percent)))
            }
        }
        return groups.map(\.peak)
    }

    /// Повтор того же замера (цифры и сбросы не изменились) не пишется;
    /// старые замеры за лимитом отбрасываются.
    nonisolated static func appending(_ sample: Sample, to samples: [Sample], limit: Int) -> [Sample] {
        if let last = samples.last,
           last.sessionPercent == sample.sessionPercent,
           last.weeklyPercent == sample.weeklyPercent,
           abs(last.sessionResetsAt.timeIntervalSince(sample.sessionResetsAt)) < 120,
           abs(last.weeklyResetsAt.timeIntervalSince(sample.weeklyResetsAt)) < 120 {
            return samples
        }
        var result = samples
        result.append(sample)
        if result.count > limit { result.removeFirst(result.count - limit) }
        return result
    }

    /// Медиана «сколько процентов недели стоит полный сеанс» по последним
    /// завершённым окнам (минимум 3), затем остаток недели / эта медиана.
    nonisolated static func forecast(samples: [Sample], session: UsageWindow, weekly: UsageWindow, now: Date) -> Forecast? {
        guard let weeklyResetsAt = weekly.resetsAt else { return nil }
        let untilWeeklyReset = weeklyResetsAt.timeIntervalSince(now)
        guard untilWeeklyReset > 0 else { return nil }

        // Замеры группируются по окну сессии (время его сброса), только завершённые окна.
        var groups: [(resetsAt: Date, samples: [Sample])] = []
        for sample in samples.sorted(by: { $0.capturedAt < $1.capturedAt }) {
            if let index = groups.firstIndex(where: { abs($0.resetsAt.timeIntervalSince(sample.sessionResetsAt)) < 120 }) {
                groups[index].samples.append(sample)
            } else {
                groups.append((sample.sessionResetsAt, [sample]))
            }
        }
        let currentReset = session.resetsAt
        let completed = groups.filter { group in
            group.resetsAt <= now && (currentReset.map { group.resetsAt < $0.addingTimeInterval(-120) } ?? true)
        }

        let burns: [Double] = completed.suffix(sampleLimit).compactMap { group in
            guard let first = group.samples.first, let last = group.samples.last,
                  abs(first.weeklyResetsAt.timeIntervalSince(last.weeklyResetsAt)) < 120
            else { return nil }
            let sessionUsed = last.sessionPercent - first.sessionPercent
            let weeklyUsed = last.weeklyPercent - first.weeklyPercent
            guard sessionUsed > 0, weeklyUsed > 0 else { return nil }
            return 100 * weeklyUsed / sessionUsed
        }
        guard burns.count >= minimumSamples else { return nil }
        let sorted = burns.sorted()
        let middle = sorted.count / 2
        let median = sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        guard median > 0 else { return nil }

        return Forecast(
            estimatedSessions: max(0, 100 - weekly.percent) / median,
            windowsUntilReset: Int(floor(untilWeeklyReset / sessionDuration))
        )
    }
}
