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
        case .custom: return Theme.mint
        }
    }
}

struct LimitsView: View {
    var store: LimitsStore
    /// Лимиты GLM Coding Plan; без ключа Z.AI стор пуст.
    var glm: LimitsStore
    var tokens: TokenStatsStore
    @Bindable var settings: AppSettings
    var uiState: PanelUIState

    /// Режим правки, как у виджетов macOS: крестики на блоках и лоток скрытых.
    @State private var isEditing: Bool

    init(store: LimitsStore, glm: LimitsStore, tokens: TokenStatsStore, settings: AppSettings, uiState: PanelUIState, editing: Bool = false) {
        self.store = store
        self.glm = glm
        self.tokens = tokens
        self.settings = settings
        self.uiState = uiState
        _isEditing = State(initialValue: editing)
    }
    @State private var frames: [LimitsBlock: CGRect] = [:]
    @State private var contentFrame = CGRect.zero
    @State private var trayFrame = CGRect.zero
    @State private var drag: Drag?

    private struct Drag: Equatable {
        let block: LimitsBlock
        var location: CGPoint
    }

    private static let space = "limits"
    private static let hourlyTitle = "Токены по часам"
    private static let dailyTitle = "Токены по дням"

    private var visible: [LimitsBlock] { settings.limitsBlocks }

    /// Вне режима правки блок без данных не занимает места.
    private var shown: [LimitsBlock] { isEditing ? visible : visible.filter(hasContent) }

    private func hasContent(_ block: LimitsBlock) -> Bool {
        switch block {
        case .claudeLimits: store.snapshot != nil || store.errorMessage != nil
        case .glmLimits: glm.snapshot != nil || glm.errorMessage != nil
        case .claudeCost: tokens.hasScanned && tokens.stats(for: store.snapshot).hasUsage
        case .claudeSessions, .claudeDailyCost: tokens.hasScanned
        case .claudePlanHistory: visible.contains(.claudeLimits) || !(store.history?.samples.isEmpty ?? true)
        case .glmDetails: glm.snapshot != nil
        case .glmHourly: series(Self.hourlyTitle) != nil
        case .glmDaily: series(Self.dailyTitle) != nil
        }
    }

    private func series(_ title: String) -> UsageSeries? {
        glm.snapshot?.series.first { $0.title == title }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            ZStack(alignment: .topLeading) {
                VStack(spacing: 8) {
                    main(now: context.date)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { contentFrame = $0 }
                    if isEditing {
                        tray
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { trayFrame = $0 }
                    }
                    footer(now: context.date)
                }
                if let drag {
                    BlockChip(block: drag.block, symbol: nil)
                        .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
                        .fixedSize()
                        .position(drag.location)
                        .allowsHitTesting(false)
                }
            }
            .coordinateSpace(.named(Self.space))
        }
    }

    @ViewBuilder
    private func main(now: Date) -> some View {
        let blocks = shown
        if !blocks.isEmpty {
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(LimitsBlock.rows(blocks), id: \.self) { row in
                        HStack(alignment: .top, spacing: 10) {
                            ForEach(row) { block in
                                cell(block, index: blocks.firstIndex(of: block) ?? 0, count: blocks.count, leadsRow: row.first == block, now: now)
                            }
                        }
                    }
                }
                .padding(.top, isEditing ? 8 : 0)
                .padding(.leading, isEditing ? 8 : 0)
            }
            .scrollIndicators(.automatic)
        } else if store.isLoading || glm.isLoading || tokens.isScanning {
            ProgressView().controlSize(.small)
        } else {
            EmptyStateView(
                icon: "gauge.with.dots.needle.50percent",
                tint: Theme.rose,
                title: visible.isEmpty ? "Все блоки скрыты" : "Лимиты недоступны",
                subtitle: visible.isEmpty
                    ? "Кнопка «Настроить блоки» внизу вернёт их"
                    : (visible.contains(.claudeLimits) ? store.errorMessage : nil) ?? "Откройте панель ещё раз, чтобы обновить"
            )
        }
    }

    // MARK: - Блоки

    private func cell(_ block: LimitsBlock, index: Int, count: Int, leadsRow: Bool, now: Date) -> some View {
        let target = dropIndex
        return VStack(spacing: 12) { blockView(block, now: now) }
            .frame(maxWidth: .infinity)
            // Место под крестик, чтобы он не закрывал заголовок блока.
            .padding(.leading, isEditing ? 14 : 0)
            .allowsHitTesting(!isEditing)
            .opacity(drag?.block == block ? 0.35 : 1)
            .overlay(alignment: leadsRow ? .top : .leading) {
                if target == index { dropMark(vertical: !leadsRow).offset(x: leadsRow ? 0 : -5, y: leadsRow ? -6 : 0) }
            }
            .overlay(alignment: .bottom) {
                if target == count, index == count - 1 { dropMark(vertical: false).offset(y: 6) }
            }
            .overlay(alignment: .topLeading) {
                if isEditing {
                    Button {
                        withAnimation(Theme.tabSpring) { settings.limitsBlocks.removeAll { $0 == block } }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Color.white.opacity(0.9)))
                    }
                    .buttonStyle(.plain)
                    .handCursor()
                    .help("Убрать блок «\(block.title)»")
                    .offset(x: -7, y: -7)
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(block), isEnabled: isEditing)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { frames[block] = $0 }
    }

    private func dropMark(vertical: Bool) -> some View {
        Capsule().fill(Theme.mint)
            .frame(width: vertical ? 3 : nil, height: vertical ? nil : 3)
    }

    @ViewBuilder
    private func blockView(_ block: LimitsBlock, now: Date) -> some View {
        if !hasContent(block) {
            placeholder(block)
        } else {
            switch block {
            case .claudeLimits:
                // Подписи разделов нужны, только когда источников два.
                if shown.contains(.glmLimits) { providerHeader("Claude", plan: store.snapshot?.plan) }
                if let snapshot = store.snapshot {
                    windows(snapshot, now: now)
                    if let forecast = store.history?.forecast(for: snapshot, now: now) {
                        Label(LimitsMenuCard.forecastText(forecast), systemImage: "wand.and.stars")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }
                } else if let error = store.errorMessage {
                    errorNote(error)
                }
            case .glmLimits:
                if shown.contains(.claudeLimits) { providerHeader("GLM · Z.AI", plan: glm.snapshot?.plan) }
                if let snapshot = glm.snapshot { windows(snapshot, now: now) }
                if let error = glm.errorMessage { errorNote(error) }
            case .claudeCost:
                let stats = tokens.stats(for: store.snapshot, now: now)
                SectionCard {
                    CostSummaryView(stats: stats)
                    RecentWindowView(stats: stats, weekly: store.snapshot?.windows.first { $0.kind == .weekly })
                    if let model = stats.topModel {
                        Text("Топ-модель: \(model) · оценка по локальным логам Claude Code по ценам API")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            case .claudeSessions:
                SectionCard(title: "Сессии Claude Code за сутки") {
                    ClaudeSessionsList(sessions: tokens.sessions)
                }
            case .claudeDailyCost:
                SectionCard(title: "Стоимость по дням") {
                    DailyUsageChart(stats: tokens.stats(for: store.snapshot, now: now), height: 80)
                }
            case .claudePlanHistory:
                SectionCard(title: "Использование плана") {
                    PlanHistoryChart(samples: store.history?.samples ?? [], height: 80)
                }
            case .glmDetails:
                if let snapshot = glm.snapshot {
                    // Пиковое время, квоты в числах и расход MCP — состав как у CodexBar.
                    SectionCard(title: "Детали квоты GLM") {
                        UsageDetailRows(details: [ZaiPeak(now: now).detail(usesCredits: snapshot.usesCredits, now: now)] + snapshot.details)
                    }
                }
            case .glmHourly, .glmDaily:
                if let series = series(block == .glmHourly ? Self.hourlyTitle : Self.dailyTitle) {
                    SectionCard(title: block.title) {
                        TokenSeriesChart(series: series, height: 80)
                    }
                }
            }
        }
    }

    /// В режиме правки блок без данных виден заглушкой — чтобы его можно было убрать или переставить.
    private func placeholder(_ block: LimitsBlock) -> some View {
        SectionCard {
            Label(block.title, systemImage: block.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
            Text(block.provider == .glm ? "Появится, когда Z.AI отдаст данные по ключу" : "Пока нет данных")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiaryText)
        }
    }

    /// Кольца 5 часов и недели, под ними полосками — остальные окна.
    @ViewBuilder
    private func windows(_ snapshot: UsageSnapshot, now: Date) -> some View {
        let rings = snapshot.windows.filter { $0.kind == .session || $0.kind == .weekly }
        let bars = snapshot.windows.filter { $0.kind != .session && $0.kind != .weekly }
        HStack(spacing: 10) {
            ForEach(rings, id: \.kind) { window in
                RingCard(window: window, now: now)
            }
        }
        ForEach(bars, id: \.kind) { window in
            BarRow(window: window, now: now)
        }
    }

    private func providerHeader(_ title: String, plan: String?) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
            Spacer()
            if let plan {
                Text(plan)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
            }
        }
        .padding(.horizontal, 4)
    }

    private func errorNote(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.amber)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }

    // MARK: - Правка

    /// Куда встанет перетаскиваемый блок; nil — курсор не над списком.
    private var dropIndex: Int? {
        guard let drag, contentFrame.contains(drag.location) else { return nil }
        return LimitsBlock.insertionIndex(frames: visible.compactMap { frames[$0] }, point: drag.location)
    }

    /// Перетаскивание жестом внутри вкладки: системный drag-and-drop в панели отдан полке файлов.
    private func dragGesture(_ block: LimitsBlock) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.space))
            .onChanged { drag = Drag(block: block, location: $0.location) }
            .onEnded { value in
                let target = dropIndex
                let overTray = trayFrame.contains(value.location)
                withAnimation(Theme.tabSpring) {
                    if let target {
                        settings.limitsBlocks = LimitsBlock.placing(block, at: target, in: visible)
                    } else if overTray {
                        settings.limitsBlocks.removeAll { $0 == block }
                    }
                    drag = nil
                }
            }
    }

    /// Лоток скрытых блоков: перетащить в список или нажать, чтобы вернуть.
    private var tray: some View {
        let hidden = LimitsBlock.allCases.filter { !visible.contains($0) }
        return VStack(alignment: .leading, spacing: 8) {
            Text(hidden.isEmpty
                ? "Все блоки на месте. Крестик убирает блок, перетаскивание меняет порядок."
                : "Скрытые блоки — перетащите в список или нажмите, чтобы вернуть")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
            if !hidden.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(hidden) { block in
                            BlockChip(block: block, symbol: "plus")
                                .opacity(drag?.block == block ? 0.35 : 1)
                                .contentShape(Capsule())
                                .onTapGesture {
                                    withAnimation(Theme.tabSpring) { settings.limitsBlocks.append(block) }
                                }
                                .gesture(dragGesture(block))
                                .handCursor()
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.card)
                .strokeBorder(Theme.mint.opacity(drag != nil && dropIndex == nil && trayFrame.contains(drag?.location ?? .zero) ? 0.6 : 0), lineWidth: 1.5)
        )
    }

    private func footer(now: Date) -> some View {
        HStack(spacing: 8) {
            // Без данных Claude его ошибка уже показана в самом блоке.
            if let error = store.errorMessage, store.snapshot != nil, visible.contains(.claudeLimits) {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.amber)
                    .lineLimit(1)
            } else if let fetchedAt = store.snapshot?.fetchedAt ?? glm.snapshot?.fetchedAt {
                Text("Обновлено \(Formatting.relative(fetchedAt, now: now))")
                    .foregroundStyle(Theme.tertiaryText)
            }
            Spacer()
            IconButton(
                systemName: isEditing ? "checkmark" : "slider.horizontal.3",
                tint: isEditing ? Theme.mint : Theme.secondaryText,
                size: 22,
                help: isEditing ? "Готово" : "Настроить блоки"
            ) {
                withAnimation(Theme.tabSpring) { isEditing.toggle() }
            }
            if store.isLoading || glm.isLoading {
                ProgressView().controlSize(.mini)
            } else {
                IconButton(systemName: "arrow.clockwise", size: 22, help: "Обновить") {
                    uiState.onRefreshLimits?()
                }
            }
        }
        .font(.system(size: 11))
    }
}

/// Блок в лотке скрытых и «призрак» под курсором при перетаскивании.
private struct BlockChip: View {
    let block: LimitsBlock
    let symbol: String?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: block.icon)
                .foregroundStyle(block.provider == .glm ? Theme.mint : Theme.sky)
            Text(block.title)
                .foregroundStyle(Theme.primaryText)
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .font(.system(size: 11.5, weight: .medium))
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Capsule().fill(Color(white: 0.2)))
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
