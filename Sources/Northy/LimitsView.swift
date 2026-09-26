import SwiftUI

extension UsageWindow {
    /// Свой цвет у каждого лимита (5 ч, неделя, модель) — одинаковый в шапке,
    /// во вкладке и на полосках; почти исчерпанный лимит краснеет.
    var accent: Color {
        if UsageLevel(percent: percent) == .critical { return Theme.danger }
        switch kind {
        case .session: return Theme.sky
        case .weekly: return Theme.violet
        case .model(let name): return name.localizedCaseInsensitiveContains("fable") ? Theme.amber : Theme.rose
        }
    }
}

struct LimitsView: View {
    var store: LimitsStore
    var tokens: TokenStatsStore

    var body: some View {
        Group {
            if let snapshot = store.snapshot {
                content(snapshot)
            } else if store.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyStateView(
                    icon: "gauge.with.dots.needle.50percent",
                    tint: Theme.rose,
                    title: "Лимиты недоступны",
                    subtitle: store.errorMessage ?? "Откройте панель ещё раз, чтобы обновить"
                )
            }
        }
    }

    private func content(_ snapshot: UsageSnapshot) -> some View {
        let rings = snapshot.windows.filter { $0.kind == .session || $0.kind == .weekly }
        let bars = snapshot.windows.filter { $0.kind != .session && $0.kind != .weekly }
        return TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(spacing: 8) {
                ScrollView {
                    VStack(spacing: 12) {
                        HStack(spacing: 10) {
                            ForEach(rings, id: \.kind) { window in
                                RingCard(window: window, now: context.date)
                            }
                        }
                        ForEach(bars, id: \.kind) { window in
                            BarRow(window: window, now: context.date)
                        }
                        if let forecast = store.history?.forecast(for: snapshot, now: context.date) {
                            Label(LimitsMenuCard.forecastText(forecast), systemImage: "wand.and.stars")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.secondaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 4)
                        }
                        costSection(snapshot, now: context.date)
                    }
                }
                .scrollIndicators(.automatic)
                footer(snapshot, now: context.date)
            }
        }
    }

    /// Стоимость по ценам API и оба графика — то же, что в меню статус-бара.
    @ViewBuilder
    private func costSection(_ snapshot: UsageSnapshot, now: Date) -> some View {
        if tokens.hasScanned {
            let stats = tokens.stats(for: snapshot, now: now)
            if stats.hasUsage {
                SectionCard {
                    CostSummaryView(stats: stats)
                    RecentWindowView(stats: stats, weekly: snapshot.windows.first { $0.kind == .weekly })
                    if let model = stats.topModel {
                        Text("Топ-модель: \(model) · оценка по локальным логам Claude Code по ценам API")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            SectionCard(title: "Сессии Claude Code за сутки") {
                ClaudeSessionsList(sessions: tokens.sessions)
            }
            HStack(alignment: .top, spacing: 10) {
                SectionCard(title: "Стоимость по дням") {
                    DailyUsageChart(stats: stats, height: 80)
                }
                SectionCard(title: "Использование плана") {
                    PlanHistoryChart(samples: store.history?.samples ?? [], height: 80)
                }
            }
        } else if tokens.isScanning {
            ProgressView().controlSize(.small).padding(.vertical, 8)
        }
    }

    private func footer(_ snapshot: UsageSnapshot, now: Date) -> some View {
        HStack(spacing: 8) {
            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.amber)
                    .lineLimit(1)
            } else {
                Text("Обновлено \(Formatting.relative(snapshot.fetchedAt, now: now))")
                    .foregroundStyle(Theme.tertiaryText)
            }
            Spacer()
            if store.isLoading {
                ProgressView().controlSize(.mini)
            } else {
                IconButton(systemName: "arrow.clockwise", size: 22, help: "Обновить") {
                    Task { await store.refresh(force: true) }
                }
            }
        }
        .font(.system(size: 11))
    }
}

private struct RingCard: View {
    let window: UsageWindow
    let now: Date

    var body: some View {
        let color = window.accent
        HStack(spacing: 16) {
            UsageRing(percent: window.percent, color: color, lineWidth: 9)
                .frame(width: 84, height: 84)
                .overlay {
                    Text("\(Int(window.percent.rounded()))%")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.primaryText)
                        .contentTransition(.numericText())
                }
            VStack(alignment: .leading, spacing: 4) {
                Text(window.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                if let resetsAt = window.resetsAt {
                    Text("сброс через \(Formatting.countdown(to: resetsAt, now: now))")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                }
                Text("осталось \(Int((100 - window.percent).rounded()))%")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(color)
                if let pace = UsagePace.make(for: window, now: now) {
                    Text([pace.summary, pace.outlook(now: now)].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.card))
        .animation(.spring(response: 0.6, dampingFraction: 0.8), value: window.percent)
    }
}

private struct BarRow: View {
    let window: UsageWindow
    let now: Date

    var body: some View {
        let color = window.accent
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(window.title)
                    .foregroundStyle(Theme.primaryText)
                Spacer()
                if let resetsAt = window.resetsAt {
                    Text("сброс через \(Formatting.countdown(to: resetsAt, now: now))")
                        .foregroundStyle(Theme.tertiaryText)
                }
                Text("\(Int(window.percent.rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(color)
            }
            .font(.system(size: 11.5, weight: .medium))
            GeometryReader { proxy in
                Capsule().fill(Color.white.opacity(0.08))
                    .overlay(alignment: .leading) {
                        Capsule().fill(color)
                            .frame(width: proxy.size.width * window.percent / 100)
                    }
            }
            .frame(height: 5)
            if let pace = UsagePace.make(for: window, now: now) {
                Text([pace.summary, pace.outlook(now: now)].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.tertiaryText)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
    }
}

/// Кольцо заполнения: серая дорожка и цветная дуга от 12 часов по часовой.
struct UsageRing: View {
    let percent: Double
    let color: Color
    var lineWidth: CGFloat = 3

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.1), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: percent / 100)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

/// Карточка раздела во вкладке «Лимиты».
private struct SectionCard<Content: View>: View {
    var title: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.card))
    }
}
