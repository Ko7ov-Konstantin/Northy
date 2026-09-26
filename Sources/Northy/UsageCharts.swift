import SwiftUI

/// Общие для меню статус-бара и вкладки «Лимиты» блоки: стоимость по ценам
/// API, график по дням и история использования плана. Цвета текста —
/// семантические, поэтому блоки работают и в системном меню, и в тёмной панели.
enum UsageChartStyle {
    /// Цвет графиков — как у полоски Fable.
    static let bar = Theme.amber
    static let ruRU = Locale(identifier: "ru_RU")

    static func dayLabel(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).locale(ruRU))
    }

    /// К концу месяца столбиков до 31 — зазор сужается, чтобы они не превращались в нитки.
    static func barSpacing(_ count: Int) -> CGFloat {
        count > 16 ? 2 : 4
    }

    static func dateTimeLabel(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(ruRU))
    }
}

/// Сводка как у CodexBar: сегодня, текущее недельное окно и месяц с 1 числа — в $ и токенах.
struct CostSummaryView: View {
    let stats: TokenStats

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            GridRow {
                stat("Сегодня", Formatting.dollars(stats.todayCost))
                stat("Оценка: текущее окно", stats.currentWeekCost.map(Formatting.dollars))
            }
            GridRow {
                stat("Токены сегодня", Formatting.tokens(stats.today))
                stat("Токены окна", stats.currentWeek.map(Formatting.tokens))
            }
            // С 1 числа текущего месяца по сегодня.
            let since = "С \(UsageChartStyle.dayLabel(stats.monthStart))"
            GridRow {
                stat("\(since): стоимость", Formatting.dollars(stats.monthToDateCost))
                stat("\(since): токены", Formatting.tokens(stats.monthToDate))
            }
        }
    }

    private func stat(_ title: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value ?? "—")
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// «Недавние окна»: текущее недельное окно лимита с датами.
struct RecentWindowView: View {
    let stats: TokenStats
    let weekly: UsageWindow?

    var body: some View {
        if let weekly, let resetsAt = weekly.resetsAt, let cost = stats.currentWeekCost, let tokens = stats.currentWeek {
            VStack(alignment: .leading, spacing: 3) {
                Text("Недавние окна")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                HStack {
                    Text("Текущее окно")
                    Spacer()
                    Text("\(Formatting.dollars(cost)) · \(Formatting.tokens(tokens))")
                        .monospacedDigit()
                }
                .font(.system(size: 11.5, weight: .medium))
                let start = resetsAt - UsagePace.duration(of: .weekly)
                Text("Оценка: \(UsageChartStyle.dateTimeLabel(start)) – \(UsageChartStyle.dateTimeLabel(resetsAt))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Столбики по дням с 1 числа месяца с переключателем «Токены / Стоимость»;
/// клик по дню — разбивка по моделям.
struct DailyUsageChart: View {
    let stats: TokenStats
    var height: CGFloat = 90

    enum Metric: String, CaseIterable { case tokens = "Токены", cost = "Стоимость" }

    private static let visibleModels = 4
    /// Заголовок дня + 4 строки моделей + «и ещё N» — место зарезервировано всегда.
    private static let breakdownHeight: CGFloat = 16 + CGFloat(visibleModels) * 31 + 14

    @State private var metric: Metric = .cost
    @State private var selected: Date?

    private func value(_ day: TokenStats.Day) -> Double {
        metric == .cost ? day.cost : Double(day.tokens)
    }

    private func label(_ value: Double) -> String {
        metric == .cost ? Formatting.dollars(value) : Formatting.tokens(Int(value))
    }

    var body: some View {
        let days = stats.daily
        let peak = max(days.map(value).max() ?? 0, 0.0001)
        let selectedDay = days.first { $0.date == selected } ?? days.last { $0.tokens > 0 }

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 6) {
                VStack(alignment: .trailing) {
                    Text(label(peak))
                    Spacer()
                    Text(label(0))
                }
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .frame(height: height)

                HStack(alignment: .bottom, spacing: UsageChartStyle.barSpacing(days.count)) {
                    ForEach(days, id: \.date) { day in
                        let isSelected = day.date == selectedDay?.date
                        RoundedRectangle(cornerRadius: 3)
                            .fill(UsageChartStyle.bar.opacity(isSelected ? 1 : 0.55))
                            .frame(height: max(2, height * value(day) / peak))
                            .frame(maxWidth: .infinity, maxHeight: height, alignment: .bottom)
                            .contentShape(Rectangle())
                            .onTapGesture { selected = day.date }
                            .onHover { if $0 { selected = day.date } }
                            .pointerStyle(.link)
                    }
                }
            }

            ChipPicker(options: Metric.allCases, selection: $metric, tint: UsageChartStyle.bar, title: \.rawValue)
                .frame(maxWidth: .infinity)

            // Высота разбивки постоянная (до 4 моделей): иначе при наведении на дни
            // с разным числом моделей подменю меняет размер и дёргается.
            VStack(alignment: .leading, spacing: 5) {
                if let day = selectedDay {
                    Text("\(UsageChartStyle.dayLabel(day.date)): \(Formatting.dollars(day.cost)) · \(Formatting.tokens(day.tokens))")
                        .font(.system(size: 11, weight: .semibold))
                    ForEach(day.models.prefix(Self.visibleModels), id: \.model) { model in
                        HStack(spacing: 8) {
                            Capsule().fill(UsageChartStyle.bar).frame(width: 3, height: 26)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(model.model).font(.system(size: 11)).lineLimit(1)
                                Text("\(Formatting.dollars(model.cost)) · \(Formatting.tokens(model.tokens))")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if day.models.count > Self.visibleModels {
                        Text("и ещё \(Formatting.plural(day.models.count - Self.visibleModels, ("модель", "модели", "моделей")))")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(height: Self.breakdownHeight, alignment: .top)

            Text("Итого с \(UsageChartStyle.dayLabel(stats.monthStart)): \(Formatting.dollars(stats.monthToDateCost))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

/// История использования плана: по столбику на окно (пик расхода в нём),
/// при наведении — пунктирная линия и подпись «дата: N% использовано».
struct PlanHistoryChart: View {
    let samples: [UsageHistory.Sample]
    var height: CGFloat = 90

    @State private var series: UsageHistory.Series = .session
    @State private var hovered: Date?

    private static let slots = 30

    var body: some View {
        let peaks = Array(UsageHistory.peaks(samples, series: series).suffix(Self.slots))
        let chosen = peaks.first { $0.date == hovered } ?? peaks.last

        VStack(alignment: .leading, spacing: 8) {
            ChipPicker(options: UsageHistory.Series.allCases, selection: $series, tint: UsageChartStyle.bar, title: \.rawValue)

            if peaks.isEmpty {
                Text("История копится при каждом обновлении лимитов")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: height)
            } else {
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(0..<Self.slots, id: \.self) { index in
                        let offset = index - (Self.slots - peaks.count)
                        let peak = offset >= 0 ? peaks[offset] : nil
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.07))
                            if let peak {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(UsageChartStyle.bar)
                                    .frame(height: max(2, height * peak.percent / 100))
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: height)
                        .overlay {
                            if let peak, peak.date == hovered {
                                DashedLine().stroke(.secondary, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            }
                        }
                        .contentShape(Rectangle())
                        .onHover { inside in
                            if inside, let peak { hovered = peak.date } else if !inside, hovered == peak?.date { hovered = nil }
                        }
                    }
                }
                HStack {
                    if let first = peaks.first { Text(UsageChartStyle.dayLabel(first.date)) }
                    Spacer()
                    if let last = peaks.last { Text(UsageChartStyle.dayLabel(last.date)) }
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                if let chosen {
                    Text("\(UsageChartStyle.dateTimeLabel(chosen.date)): \(Int(chosen.percent.rounded()))% использовано")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Вертикальная линия по центру — отметка наведённого столбика.
nonisolated private struct DashedLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return path
    }
}

/// Рамка графика в подменю статус-бара: фиксированная ширина и отступы меню.
struct ChartMenuContainer<Content: View>: View {
    let content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(width: 340, alignment: .leading)
    }
}

/// Сессии Claude Code за сутки: идёт ли сейчас, папка, модель, когда был
/// последний ответ и сколько стоила сегодня.
struct ClaudeSessionsList: View {
    let sessions: [ClaudeSession]
    var limit = 6

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 7) {
                if sessions.isEmpty {
                    Text("За последние сутки сессий не было")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                ForEach(sessions.prefix(limit)) { session in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(session.isActive(now: context.date) ? Theme.mint : Color.secondary.opacity(0.4))
                            .frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(session.project)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                            Text("\(Self.shortModel(session.model)) · \(Formatting.relative(session.lastActivity, now: context.date))")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(Formatting.dollars(session.todayCost))
                                .font(.system(size: 12, weight: .semibold))
                                .monospacedDigit()
                            Text(Formatting.tokens(session.todayTokens))
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .help(session.isActive(now: context.date) ? "Идёт прямо сейчас" : "Последний ответ \(Formatting.relative(session.lastActivity, now: context.date))")
                }
                if sessions.count > limit {
                    Text("и ещё \(Formatting.plural(sessions.count - limit, ("сессия", "сессии", "сессий")))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// «claude-opus-5-5» → «opus-5-5»: в узкой строке префикс ничего не добавляет.
    static func shortModel(_ model: String) -> String {
        model.hasPrefix("claude-") ? String(model.dropFirst("claude-".count)) : model
    }
}
