import Foundation
import Observation

/// Окно лимита подписки Claude: процент использования и время сброса.
nonisolated struct UsageWindow: Equatable, Sendable {
    enum Kind: Hashable, Sendable {
        case session
        /// Недельный лимит по всем моделям.
        case weekly
        /// Недельный лимит отдельной модели (Fable, Sonnet…).
        case model(String)
        /// Окно со своей подписью и длительностью (GLM: месячный лимит MCP и т. п.).
        case custom(String)
    }

    let kind: Kind
    let percent: Double
    let resetsAt: Date?
    /// Длина окна; по умолчанию — по виду: 5 часов у сеанса, неделя у остальных.
    let duration: TimeInterval

    init(kind: Kind, percent: Double, resetsAt: Date?, duration: TimeInterval? = nil) {
        self.kind = kind
        self.percent = min(100, max(0, percent))
        self.resetsAt = resetsAt
        self.duration = duration ?? UsagePace.duration(of: kind)
    }

    var remaining: Int { 100 - Int(percent.rounded()) }

    var title: String {
        switch kind {
        case .session: "5 часов"
        case .weekly: "Неделя · все модели"
        case .model(let name): "Неделя · \(name)"
        case .custom(let name): name
        }
    }

    /// Подпись для тесных мест: строка меню, шапка панели.
    var shortTitle: String {
        switch kind {
        case .session: "5ч"
        case .weekly: "7д"
        case .model(let name), .custom(let name): name
        }
    }
}

/// Строка справки под лимитами: «Квота MCP — 22% использовано — лимит 1000».
nonisolated struct UsageDetail: Equatable, Sendable {
    let label: String
    let value: String
    var note: String? = nil
}

/// Расход токенов по времени и по моделям — для графика.
nonisolated struct UsageSeries: Equatable, Sendable {
    struct Point: Equatable, Sendable {
        let label: String
        let value: Int
    }

    struct Total: Equatable, Sendable {
        let name: String
        let tokens: Int
    }

    let title: String
    let points: [Point]
    let totals: [Total]
}

nonisolated struct UsageSnapshot: Equatable, Sendable {
    let windows: [UsageWindow]
    let fetchedAt: Date
    /// План подписки («Max 20x»), если claude.ai его отдал.
    var plan: String? = nil
    /// Справочные строки и графики источника; у Claude пусто.
    var details: [UsageDetail] = []
    var series: [UsageSeries] = []
    /// Тариф GLM считает кредиты: в пиковое время списание вдвое дороже.
    var usesCredits = false

    /// Главное число для строки меню и шапки: сессия, а без неё — неделя.
    var headline: UsageWindow? {
        windows.first { $0.kind == .session } ?? windows.first { $0.kind == .weekly }
    }

    /// Остаток по 5 ч и общей неделе — строки друг под другом в строке меню:
    /// «5ч 58%» / «7д 22%». Лимиты отдельных моделей сюда не идут.
    var statusBarLines: [String] {
        windows
            .filter { $0.kind == .session || $0.kind == .weekly }
            .map { "\($0.shortTitle) \($0.remaining)%" }
    }
}

enum UsageLevel: Equatable {
    case normal, elevated, critical

    init(percent: Double) {
        switch percent {
        case ..<60: self = .normal
        case ..<85: self = .elevated
        default: self = .critical
        }
    }
}

/// Откуда берутся лимиты. Источник подключается отдельно от интерфейса.
protocol LimitsSource {
    func fetch() async throws -> UsageSnapshot
}

struct UnconfiguredLimitsSource: LimitsSource {
    struct NotConfigured: LocalizedError {
        var errorDescription: String? { "Источник лимитов ещё не подключён" }
    }

    func fetch() async throws -> UsageSnapshot {
        throw NotConfigured()
    }
}

/// Лимиты обновляются только по событию (открытие панели или меню), без
/// фонового опроса; частые открытия подряд не дёргают источник.
@MainActor
@Observable
final class LimitsStore {
    private(set) var snapshot: UsageSnapshot?
    private(set) var errorMessage: String?
    private(set) var isLoading = false
    var source: any LimitsSource
    /// Замеры для оценки «сколько сеансов осталось»; nil в тестах стора.
    let history: UsageHistory?

    private let minInterval: TimeInterval
    private var lastAttempt: Date?
    /// Растёт при reset(): ответ запроса, начатого до сброса, отбрасывается.
    private var generation = 0

    init(source: any LimitsSource = UnconfiguredLimitsSource(), minInterval: TimeInterval = 60, history: UsageHistory? = nil) {
        self.source = source
        self.history = history
        self.minInterval = minInterval
    }

    /// Источник отключён (ключ удалён) — прежние цифры и ошибка больше не показываются.
    func reset() {
        generation += 1
        snapshot = nil
        errorMessage = nil
        lastAttempt = nil
        isLoading = false
    }

    func refresh(force: Bool = false) async {
        guard !isLoading else { return }
        if !force, let lastAttempt, Date().timeIntervalSince(lastAttempt) < minInterval { return }
        lastAttempt = Date()
        isLoading = true
        let started = generation
        let result: Result<UsageSnapshot, Error>
        do {
            result = .success(try await source.fetch())
        } catch {
            result = .failure(error)
        }
        guard started == generation else { return }
        isLoading = false
        switch result {
        case .success(let fresh):
            snapshot = fresh
            history?.record(fresh)
            errorMessage = nil
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }
}

/// Темп расхода окна — формула CodexBar (UsagePace.weekly): ожидаемый расход
/// равен доле прошедшего времени окна; отстаём — резерв, обгоняем — дефицит.
nonisolated struct UsagePace: Equatable, Sendable {
    let deltaPercent: Double
    let willLastToReset: Bool
    /// Через сколько секунд лимит кончится при текущей скорости; nil — хватит.
    let etaSeconds: TimeInterval?

    static func duration(of kind: UsageWindow.Kind) -> TimeInterval {
        kind == .session ? 5 * 3600 : 7 * 86_400
    }

    static func make(for window: UsageWindow, now: Date = .now) -> UsagePace? {
        guard let resetsAt = window.resetsAt else { return nil }
        let duration = window.duration
        let untilReset = resetsAt.timeIntervalSince(now)
        guard untilReset > 0, untilReset <= duration else { return nil }
        let elapsed = min(duration, max(0, duration - untilReset))
        let actual = window.percent
        if elapsed == 0, actual > 0 { return nil }
        let expected = min(100, max(0, elapsed / duration * 100))

        var willLast = false
        var eta: TimeInterval?
        if actual >= 100 {
            eta = 0
        } else if elapsed > 0, actual > 0 {
            let candidate = (100 - actual) / (actual / elapsed)
            if candidate >= untilReset { willLast = true } else { eta = candidate }
        } else if elapsed > 0 {
            willLast = true
        }
        return UsagePace(deltaPercent: actual - expected, willLastToReset: willLast, etaSeconds: eta)
    }

    /// «21% в резерве», «30% в дефиците», «В темпе» (разница до 2%).
    var summary: String {
        let value = Int(abs(deltaPercent).rounded())
        guard abs(deltaPercent) > 2, value > 0 else { return "В темпе" }
        return deltaPercent > 0 ? "\(value)% в дефиците" : "\(value)% в резерве"
    }

    func outlook(now: Date = .now) -> String? {
        if willLastToReset { return "Действует до сброса" }
        guard let etaSeconds else { return nil }
        return etaSeconds <= 0 ? "Лимит исчерпан" : "Закончится через \(Formatting.countdown(to: now + etaSeconds, now: now))"
    }
}
