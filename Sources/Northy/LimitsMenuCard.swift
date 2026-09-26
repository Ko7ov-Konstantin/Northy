import SwiftUI

/// Карточка лимитов в меню статус-бара — по образцу CodexBar: остаток по
/// каждому окну, время до сброса и полоска. Цвета системные — меню
/// светлое или тёмное вместе с системой.
struct LimitsMenuCard: View {
    var store: LimitsStore
    var tokens: TokenStatsStore

    @State private var isHovering = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 12) {
                header(now: context.date)
                Divider()
                if let snapshot = store.snapshot {
                    ForEach(snapshot.windows, id: \.kind) { window in
                        row(window, now: context.date)
                    }
                } else if store.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                }
                tokenSection(now: context.date)
                if let error = store.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 6)
            .frame(width: 300, alignment: .leading)
            // Подсветка при наведении — карточка раскрывает подменю, как обычный пункт.
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(isHovering ? 0.12 : 0))
                    .padding(.horizontal, 5)
            )
            .onHover { isHovering = $0 }
        }
    }

    /// Стоимость и токены по локальным логам Claude Code — как у CodexBar.
    @ViewBuilder
    private func tokenSection(now: Date) -> some View {
        if tokens.hasScanned {
            let stats = tokens.stats(for: store.snapshot, now: now)
            if stats.lastTenDays > 0 {
                Divider()
                CostSummaryView(stats: stats)
                costChart(stats.daily)
                RecentWindowView(stats: stats, weekly: store.snapshot?.windows.first { $0.kind == .weekly })
                VStack(alignment: .leading, spacing: 2) {
                    if let model = stats.topModel {
                        Text("Топ-модель: \(model)")
                    }
                    Text("Оценка по локальным логам Claude Code по ценам API")
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        } else if tokens.isScanning {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
        }
    }

    /// Стоимость по дням за 10 дней; самый дорогой день — с подписью.
    private func costChart(_ days: [TokenStats.Day]) -> some View {
        let peak = max(days.map(\.cost).max() ?? 0, 0.0001)
        return VStack(alignment: .trailing, spacing: 3) {
            Text(Formatting.dollars(peak))
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(days, id: \.date) { day in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(UsageChartStyle.bar.opacity(day.cost == peak ? 1 : 0.6))
                        .frame(height: max(2, 56 * day.cost / peak))
                        .frame(maxWidth: .infinity)
                        .help("\(UsageChartStyle.dayLabel(day.date)): \(Formatting.dollars(day.cost)) · \(Formatting.tokens(day.tokens))")
                }
            }
            .frame(height: 56, alignment: .bottom)
        }
    }

    private func header(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Claude")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                // У карточки есть подменю с графиком стоимости — стрелка, как у обычного пункта.
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            HStack {
                if store.isLoading {
                    Text("Обновляется…")
                } else if let snapshot = store.snapshot {
                    Text("Обновлено \(Formatting.relative(snapshot.fetchedAt, now: now))")
                } else {
                    Text("Нет данных")
                }
                Spacer()
                if let plan = store.snapshot?.plan {
                    Text(plan)
                }
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
        }
    }

    private func row(_ window: UsageWindow, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(Self.menuTitle(window)) \(window.remaining)% осталось")
                .font(.system(size: 12, weight: .semibold))
            if let resetsAt = window.resetsAt {
                Text("Сбрасывается через \(Formatting.countdown(to: resetsAt, now: now))")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            GeometryReader { proxy in
                Capsule().fill(Color.primary.opacity(0.12))
                    .overlay(alignment: .leading) {
                        Capsule().fill(window.accent)
                            .frame(width: proxy.size.width * CGFloat(window.remaining) / 100)
                    }
            }
            .frame(height: 6)
            if let pace = UsagePace.make(for: window, now: now) {
                Text([pace.summary, pace.outlook(now: now)].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            if window.kind == .weekly, let snapshot = store.snapshot,
               let forecast = store.history?.forecast(for: snapshot, now: now) {
                Text(Self.forecastText(forecast))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// «Оценка: 3,9 сеанса осталось · 3 окна до сброса».
    static func forecastText(_ forecast: UsageHistory.Forecast) -> String {
        let rounded = (forecast.estimatedSessions * 10).rounded() / 10
        let sessions: String
        if rounded == rounded.rounded() {
            sessions = Formatting.plural(Int(rounded), ("сеанс", "сеанса", "сеансов"))
        } else {
            sessions = rounded.formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier: "ru_RU"))) + " сеанса"
        }
        let windows = Formatting.plural(forecast.windowsUntilReset, ("окно", "окна", "окон"))
        return "Оценка: \(sessions) осталось · \(windows) до сброса"
    }

    private static func menuTitle(_ window: UsageWindow) -> String {
        switch window.kind {
        case .session: "Сеанс"
        case .weekly: "Недельный"
        case .model(let name): "\(name) за неделю"
        }
    }
}

/// «Обновить» в меню статус-бара: выглядит как обычный пункт, но клик по нему
/// не закрывает меню (так ведут себя пункты с собственным видом). На время
/// обновления вместо «⌘R» — индикатор.
struct RefreshMenuRow: View {
    var limits: LimitsStore
    var tokens: TokenStatsStore
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        let isBusy = limits.isLoading || tokens.isScanning
        HStack(spacing: 6) {
            Text("Обновить")
            Spacer()
            if isBusy {
                ProgressView().controlSize(.mini)
            } else {
                Text("⌘R")
                    .foregroundStyle(isHovering ? AnyShapeStyle(Color.white.opacity(0.75)) : AnyShapeStyle(.tertiary))
            }
        }
        .font(Font(NSFont.menuFont(ofSize: 0)))
        .foregroundStyle(isHovering ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(isHovering ? Color.accentColor : .clear))
        .padding(.horizontal, 5)
        .frame(width: 300)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(perform: action)
    }
}
