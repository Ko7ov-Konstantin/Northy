import AppKit
import SwiftUI

enum PanelTab: String, CaseIterable, Identifiable, Hashable {
    case clipboard, files, translator, limits

    var id: Self { self }

    private static let storageKey = "panel.selectedTab"

    /// Последняя открытая вкладка; первый запуск или мусор в настройках — «Буфер».
    static func stored(in defaults: UserDefaults = .standard) -> PanelTab {
        defaults.string(forKey: storageKey).flatMap(PanelTab.init(rawValue:)) ?? .clipboard
    }

    func store(in defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.storageKey)
    }

    var title: String {
        switch self {
        case .clipboard: "Буфер"
        case .files: "Файлы"
        case .translator: "Переводчик"
        case .limits: "Лимиты"
        }
    }

    var icon: String {
        switch self {
        case .clipboard: "doc.on.clipboard"
        case .files: "tray.full"
        case .translator: "character.bubble"
        case .limits: "gauge.with.dots.needle.50percent"
        }
    }

    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    /// Включённые вкладки в обычном порядке.
    static func visible(enabled: Set<PanelTab>) -> [PanelTab] {
        allCases.filter { enabled.contains($0) }
    }

    /// Выключенную вкладку не открываем — вместо неё «Буфер».
    static func resolve(_ tab: PanelTab, enabled: Set<PanelTab>) -> PanelTab {
        enabled.contains(tab) ? tab : .clipboard
    }
}

/// Корень панели — тёмный «остров», вырастающий из выреза. Окно уже имеет
/// развёрнутый размер, а форма анимирует свой размер от выреза до полного:
/// так выглядит «Dynamic Island», а не резкая смена фрейма окна.
struct PanelRootView: View {
    var uiState: PanelUIState
    var clipboardStore: ClipboardStore
    var shelfStore: ShelfStore
    var limitsStore: LimitsStore
    var tokenStore: TokenStatsStore

    private static let earRadius: CGFloat = 12
    private static let bottomRadius: CGFloat = 30

    private var isExpanded: Bool { uiState.isExpanded }

    private var islandSize: CGSize {
        isExpanded ? uiState.expandedSize : uiState.collapsedSize
    }

    private var shape: IslandShape {
        IslandShape(
            topRadius: isExpanded ? Self.earRadius : 4,
            bottomRadius: isExpanded ? Self.bottomRadius : 10
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            background
            // Содержимое всегда в дереве: свёртывание не сбрасывает набранный
            // в переводчике текст и прокрутку истории.
            expandedContent
                .frame(width: uiState.expandedSize.width, height: uiState.expandedSize.height, alignment: .top)
                .opacity(isExpanded ? 1 : 0)
                .scaleEffect(isExpanded ? 1 : 0.92, anchor: .top)
                .blur(radius: isExpanded ? 0 : 8)
                .allowsHitTesting(isExpanded)
                .animation(
                    isExpanded ? .easeOut(duration: 0.28).delay(0.06) : .easeIn(duration: 0.12),
                    value: isExpanded
                )
        }
        .frame(width: islandSize.width, height: islandSize.height, alignment: .top)
        .clipShape(shape)
        .overlay {
            shape
                .stroke(
                    LinearGradient(colors: [.clear, Theme.edge], startPoint: .top, endPoint: .bottom),
                    lineWidth: 1
                )
                .opacity(isExpanded ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    private var background: some View {
        ZStack(alignment: .top) {
            LinearGradient(
                colors: [Theme.islandTop, Theme.islandBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            // Мягкое свечение цвета текущей вкладки под шапкой.
            EllipticalGradient(
                colors: [uiState.selectedTab.tint.opacity(0.16), .clear],
                center: .center,
                startRadiusFraction: 0,
                endRadiusFraction: 0.5
            )
            .frame(width: 540, height: 180)
            .offset(y: uiState.topInset - 50)
                .opacity(isExpanded ? 1 : 0)
                .animation(.easeInOut(duration: 0.4), value: uiState.selectedTab)
        }
    }

    private var expandedContent: some View {
        VStack(spacing: 0) {
            HeaderBar(
                uiState: uiState,
                clipboardStore: clipboardStore,
                shelfStore: shelfStore,
                limitsStore: limitsStore
            )
            .padding(.horizontal, Self.earRadius + 10)
            .frame(height: max(uiState.topInset, 38))

            ZStack {
                tabLayer(.clipboard) { ClipboardView(store: clipboardStore, uiState: uiState) }
                // Выключенные в настройках вкладки не строятся вовсе.
                if uiState.enabledTabs.contains(.files) {
                    tabLayer(.files) { ShelfView(store: shelfStore) }
                }
                if uiState.enabledTabs.contains(.translator) {
                    tabLayer(.translator) { TranslatorView() }
                }
                if uiState.enabledTabs.contains(.limits) {
                    tabLayer(.limits) { LimitsView(store: limitsStore, tokens: tokenStore) }
                }
            }
            .padding(.horizontal, Self.earRadius + 12)
            .padding(.top, 8)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .overlay { DropHighlight(isActive: uiState.isDropTargeted, topInset: uiState.topInset) }
        .overlay(alignment: .bottomTrailing) {
            // Уголок живёт в нижнем отступе острова (16 пт), где нет содержимого:
            // раньше он перекрывал «Обновить» и «Копировать» в правом нижнем углу.
            ResizeHandle(uiState: uiState)
                .padding(.trailing, Self.earRadius + 5)
                .padding(.bottom, 1)
        }
        // Свернули под неподвижным курсором — onHover(false) может не прийти.
        .environment(\.hoverGlowEnabled, isExpanded)
    }

    /// Вкладки не пересоздаются — переключение сдвигает их по горизонтали в
    /// сторону выбранной и растворяет. opacity(0) в ZStack не выключает
    /// hit-testing — скрытая вкладка перехватывала бы клики, отсюда allowsHitTesting.
    @ViewBuilder
    private func tabLayer<Content: View>(_ tab: PanelTab, @ViewBuilder content: () -> Content) -> some View {
        let selected = uiState.selectedTab
        let isSelected = selected == tab
        content()
            .opacity(isSelected ? 1 : 0)
            .offset(x: isSelected ? 0 : CGFloat(tab.index - selected.index) * 24)
            .blur(radius: isSelected ? 0 : 6)
            .allowsHitTesting(isSelected)
            .animation(Theme.tabSpring, value: selected)
            .environment(\.hoverGlowEnabled, isSelected && isExpanded)
    }
}

/// Шапка: вкладки — в левом «ухе» выреза, счётчик и действия — в правом.
/// На экране без выреза та же строка просто идёт первой строкой панели.
private struct HeaderBar: View {
    var uiState: PanelUIState
    var clipboardStore: ClipboardStore
    var shelfStore: ShelfStore
    var limitsStore: LimitsStore

    @Namespace private var pillNamespace

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(PanelTab.visible(enabled: uiState.enabledTabs)) { tab in
                    TabPill(tab: tab, isSelected: uiState.selectedTab == tab, namespace: pillNamespace) {
                        withAnimation(Theme.tabSpring) { uiState.selectedTab = tab }
                    }
                }
            }
            Spacer(minLength: uiState.notchWidth + 16)
            HStack(spacing: 6) {
                if uiState.enabledTabs.contains(.limits) {
                    LimitsBadge(store: limitsStore) {
                        withAnimation(Theme.tabSpring) { uiState.selectedTab = .limits }
                    }
                }
                trailingInfo
                IconButton(systemName: "gearshape", help: "Настройки  ⌘,") {
                    uiState.onOpenSettings?()
                }
                IconButton(systemName: "power", hoverTint: Theme.danger, help: "Выйти из Northy") {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    @ViewBuilder
    private var trailingInfo: some View {
        switch uiState.selectedTab {
        case .clipboard:
            if !clipboardStore.history.isEmpty {
                CountBadge(text: "\(clipboardStore.history.count)", tint: Theme.sky)
                ConfirmClearButton { withAnimation(Theme.tabSpring) { clipboardStore.clear() } }
            }
        case .files:
            if !shelfStore.files.isEmpty {
                CountBadge(text: "\(shelfStore.files.count)", tint: Theme.amber)
                ConfirmClearButton { withAnimation(Theme.tabSpring) { shelfStore.clear() } }
            }
        case .translator, .limits:
            EmptyView()
        }
    }
}

/// Остаток по всем лимитам в шапке — маленькие кольца с цифрой внутри,
/// видны на любой вкладке; клик ведёт на «Лимиты».
private struct LimitsBadge: View {
    var store: LimitsStore
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.hoverGlowEnabled) private var glowEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var lit: Bool { isHovering && glowEnabled }

    var body: some View {
        if let windows = store.snapshot?.windows, !windows.isEmpty {
            Button(action: action) {
                HStack(spacing: 4) {
                    ForEach(Array(windows.enumerated()), id: \.element.kind) { index, window in
                        UsageRing(percent: Double(window.remaining), color: window.accent, lineWidth: 2)
                            .frame(width: 22, height: 22)
                            .overlay {
                                Text("\(window.remaining)")
                                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(Theme.primaryText)
                                    .contentTransition(.numericText())
                            }
                            // Каждое кольцо светится своим цветом, волной слева направо.
                            .background {
                                ZStack {
                                    if lit {
                                        Circle().fill(window.accent.opacity(0.32)).blur(radius: 4)
                                    }
                                }
                                .animation(fade, value: lit)
                            }
                            .animation(ringAnimation(index)) {
                                $0.scaleEffect(lit && !reduceMotion ? 1.08 : 1)
                            }
                            .help("\(window.title): осталось \(window.remaining)%")
                    }
                }
                // Затухание — только на слоях подсветки: numericText в кольцах не трогается.
                .background {
                    ZStack {
                        if lit {
                            Capsule().fill(Color.white.opacity(0.06)).padding(-3)
                        }
                    }
                    .animation(fade, value: lit)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .handCursor()
            .onHover { isHovering = $0 }
            .onChange(of: glowEnabled) { _, on in if !on { isHovering = false } }
        }
    }

    private var fade: Animation { reduceMotion ? Hover.reduced : Hover.fade }

    private func ringAnimation(_ index: Int) -> Animation {
        if reduceMotion { return Hover.reduced }
        return lit ? Hover.enter.delay(Double(index) * 0.025) : Hover.exit
    }
}

private struct CountBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(Capsule().fill(tint.opacity(0.14)))
            .contentTransition(.numericText())
            .animation(Theme.tabSpring, value: text)
    }
}

private struct TabPill: View {
    let tab: PanelTab
    let isSelected: Bool
    let namespace: Namespace.ID
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.hoverGlowEnabled) private var glowEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var lit: Bool { isHovering && glowEnabled }

    /// Кнопка, подпись и фон не масштабируются: в фоне летит matched-капсула,
    /// любой масштаб сдвинул бы её старт при переключении. Приподнимается только иконка.
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: tab.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isSelected ? tab.tint : (lit ? tab.tint.opacity(0.9) : Theme.secondaryText))
                    .animation(fade, value: lit)
                    .animation(lit ? Hover.enter : Hover.exit) {
                        $0.scaleEffect(lit && !reduceMotion ? 1.12 : 1)
                    }
                if isSelected {
                    Text(tab.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                        .fixedSize()
                        .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .leading)))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            // Затухание — только на слоях подсветки: matched-капсула под него не попадает.
            .background {
                if isSelected {
                    // Кромка — внутри matched-капсулы, чтобы при переключении летела вместе с ней.
                    Capsule()
                        .fill(tab.tint.opacity(0.2))
                        .overlay {
                            ZStack { if lit { rim(0.55) } }
                                .animation(fade, value: lit)
                        }
                        .matchedGeometryEffect(id: "tabPill", in: namespace)
                } else {
                    // Наведение заранее показывает цвет вкладки — по клику он перетекает в капсулу.
                    ZStack {
                        if lit {
                            Capsule()
                                .fill(tab.tint.opacity(0.10))
                                .overlay { rim(0.35) }
                        }
                    }
                    .animation(fade, value: lit)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .handCursor()
        .onHover { isHovering = $0 }
        .onChange(of: glowEnabled) { _, on in if !on { isHovering = false } }
        .help(tab.title)
    }

    private var fade: Animation { reduceMotion ? Hover.reduced : Hover.fade }

    private func rim(_ top: Double) -> some View {
        Capsule()
            .strokeBorder(
                LinearGradient(colors: [tab.tint.opacity(top), tab.tint.opacity(0.05)], startPoint: .top, endPoint: .bottom),
                lineWidth: 0.75
            )
            .allowsHitTesting(false)
    }
}

/// Рамка «отпустите здесь» поверх всей панели, пока над ней тащат файл.
private struct DropHighlight: View {
    let isActive: Bool
    let topInset: CGFloat

    var body: some View {
        ZStack {
            if isActive {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Theme.amber.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(Theme.amber.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
                    )
                    .overlay(alignment: .bottom) {
                        Label("Отпустите — положу на полку", systemImage: "tray.and.arrow.down.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.amber)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(Color.black.opacity(0.7)))
                            .padding(.bottom, 14)
                    }
                    .padding(EdgeInsets(top: max(topInset, 38) + 4, leading: 18, bottom: 14, trailing: 18))
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .animation(.easeOut(duration: 0.18), value: isActive)
        .allowsHitTesting(false)
    }
}

/// Уголок для растягивания панели. Смещение считается по экранным координатам
/// мыши: окно под курсором меняет размер, и локальные координаты «плывут».
private struct ResizeHandle: View {
    var uiState: PanelUIState

    @State private var start: (mouse: NSPoint, size: CGSize)?
    @State private var isHovering = false

    var body: some View {
        GripShape()
            .stroke(Color.white.opacity(isHovering || start != nil ? 0.55 : 0.22), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
            .frame(width: 9, height: 9)
            .frame(width: 26, height: 14)
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .pointerStyle(.frameResize(position: .bottomTrailing))
            .onContinuousHover { phase in
                if case .active = phase {
                    PanelCursor.overResize = true
                    NSCursor.frameResize(position: .bottomRight, directions: .all).set()
                } else {
                    PanelCursor.overResize = false
                }
            }
            .help("Потяните, чтобы изменить размер панели")
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { _ in
                        let mouse = NSEvent.mouseLocation
                        if start == nil {
                            start = (mouse, NotchGeometry.contentSize)
                            uiState.isResizing = true
                        }
                        guard let start else { return }
                        // Панель растёт в обе стороны от выреза — ширина меняется на двойное смещение.
                        uiState.onResize?(CGSize(
                            width: start.size.width + 2 * (mouse.x - start.mouse.x),
                            height: start.size.height + (start.mouse.y - mouse.y)
                        ))
                    }
                    .onEnded { _ in
                        start = nil
                        uiState.onResizeEnded?()
                    }
            )
            .animation(.easeOut(duration: 0.15), value: isHovering)
    }
}

/// Две диагональные чёрточки — привычный вид уголка изменения размера.
nonisolated private struct GripShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.move(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return path
    }
}
