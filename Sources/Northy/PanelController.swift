import AppKit
import SwiftUI

/// Общее UI-состояние панели, разделяемое между AppKit (геометрия окна)
/// и SwiftUI (анимация содержимого).
@MainActor
@Observable
final class PanelUIState {
    var isExpanded = false
    var selectedTab: PanelTab = .clipboard
    /// Высота выреза — отступ сверху, ниже которого начинается читаемый контент.
    var topInset: CGFloat = 0
}

/// Рекурсивно снимает регистрацию dragged types у вью и всех его потомков.
/// SwiftUI-контент содержит AppKit-вью, которые сами регистрируются на драг
/// (в первую очередь NSTextView внутри TextEditor переводчика) — в глубине
/// дерева они перехватывают drag-сессию у DropContainerView раньше, чем
/// курсор доходит до дна панели. Дёшево — вызывается при старте и при каждом
/// развороте, поскольку SwiftUI может домонтировать такие вью лениво.
private extension NSView {
    func unregisterDraggedTypesRecursively() {
        unregisterDraggedTypes()
        for subview in subviews {
            subview.unregisterDraggedTypesRecursively()
        }
    }
}

/// NSHostingView, которая ловит mouseEntered/mouseExited через NSTrackingArea.
final class TrackingHostingView<Content: View>: NSHostingView<Content> {
    var onMouseEntered: (() -> Void)?
    var onMouseExited: (() -> Void)?

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onMouseEntered?()
    }

    override func mouseExited(with event: NSEvent) {
        onMouseExited?()
    }
}

@MainActor
final class PanelController {

    private var panel: NotchPanel!
    private var hostingView: NSView!
    private var effectView: NSVisualEffectView!
    let uiState = PanelUIState()
    let clipboardStore = ClipboardStore()
    let shelfStore = ShelfStore()

    private var collapseWorkItem: DispatchWorkItem?
    private var dragMonitor: Any?
    private static let collapseDelay: TimeInterval = 0.35
    private static let collapseAnimationDuration: TimeInterval = 0.35
    private static let focusRecheckDelay: TimeInterval = 1.0
    private static let expandedCornerRadius: CGFloat = 24

    func start() {
        clipboardStore.start()
        uiState.topInset = NotchGeometry.notchHeight()

        let collapsedFrame = NotchGeometry.collapsedFrame()
        panel = NotchPanel(contentRect: collapsedFrame)
        panel.onEscape = { [weak self] in self?.collapse() }

        let rootView = PanelRootView(
            uiState: uiState,
            clipboardStore: clipboardStore,
            shelfStore: shelfStore
        )
        let hostingView = TrackingHostingView(rootView: rootView)
        hostingView.onMouseEntered = { [weak self] in self?.handleMouseEntered() }
        hostingView.onMouseExited = { [weak self] in self?.handleMouseExited() }
        self.hostingView = hostingView

        // DropContainerView — прозрачный для кликов оверлей ПОВЕРХ hostingView (не
        // контейнер под ним): в глубине SwiftUI-дерева живут AppKit-вью (NSTextView
        // и т.п.), которые сами регистрируются на драг и в нижней части панели
        // перехватывали drag-сессию раньше нашего вью. hitTest у оверлея возвращает
        // nil, поэтому клики/жесты проходят насквозь к SwiftUI как раньше.
        let rootContainer = NSView(frame: CGRect(origin: .zero, size: collapsedFrame.size))

        // SwiftUI .regularMaterial внутри окна блюрит только пустоту за собой (окно
        // прозрачное) — настоящий блюр рабочего стола/окон под панелью даёт только
        // AppKit-уровневый NSVisualEffectView с blendingMode = .behindWindow. Нижний
        // слой контейнера; скрыт в свёрнутом виде — там просто чёрная полоска, блюрить нечего.
        let effectView = NSVisualEffectView(frame: rootContainer.bounds)
        effectView.autoresizingMask = [.width, .height]
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.material = .hudWindow
        effectView.wantsLayer = true
        effectView.layer?.cornerCurve = .continuous
        effectView.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        effectView.isHidden = true
        self.effectView = effectView
        rootContainer.addSubview(effectView)

        hostingView.frame = rootContainer.bounds
        hostingView.autoresizingMask = [.width, .height]
        rootContainer.addSubview(hostingView)

        let dropOverlay = DropContainerView(frame: rootContainer.bounds)
        dropOverlay.autoresizingMask = [.width, .height]
        dropOverlay.onFileURLs = { [weak self] urls in
            self?.shelfStore.add(urls)
            self?.uiState.selectedTab = .files
        }
        rootContainer.addSubview(dropOverlay, positioned: .above, relativeTo: hostingView)
        panel.contentView = rootContainer

        hostingView.unregisterDraggedTypesRecursively()

        panel.setFrame(collapsedFrame, display: true)
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        // Клик в другое приложение снимает key у панели — если мышь при этом уже вне
        // панели, сворачиваем сразу, не дожидаясь старого таймера mouseExited.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResignKey),
            name: NSWindow.didResignKeyNotification,
            object: panel
        )

        // NSTrackingArea не шлёт mouseEntered/mouseExited во время drag-сессии
        // (macOS-ограничение), поэтому наведение перетаскиваемого файла на свёрнутый
        // вырез ловим глобальным монитором мыши — он не требует Accessibility (в отличие
        // от клавиатурных событий). mouseUp в том же мониторе ловит конец drag-сессии:
        // без него drag, отменённый вне панели, оставлял панель развёрнутой навсегда.
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            Task { @MainActor in self?.handleDragMonitorEvent(event) }
        }
    }

    private func handleDragMonitorEvent(_ event: NSEvent) {
        if event.type == .leftMouseUp {
            // Drag закончился (дроп или отмена). Если мышь вне панели — проверяем
            // сворачивание: mouseExited во время drag-сессии не приходил.
            if uiState.isExpanded, !panel.frame.contains(NSEvent.mouseLocation) {
                scheduleCollapseCheck(after: Self.collapseDelay)
            }
            return
        }

        guard !uiState.isExpanded else { return }
        guard NSEvent.pressedMouseButtons & 1 != 0 else { return }
        guard NotchGeometry.collapsedFrame().contains(NSEvent.mouseLocation) else { return }

        handleDragEntered()
        // Перерегистрация окна сразу после ресайза по drag-монитору — подстраховка
        // на случай отставания window server от setFrame во время активной drag-сессии.
        panel.orderOut(nil)
        panel.orderFrontRegardless()
    }

    private func handleMouseEntered() {
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
        expand()
    }

    /// Тот же путь, что при hover, плюс переключение на вкладку «Файлы» —
    /// чтобы перетащенный файл сразу стало видно на полке.
    private func handleDragEntered() {
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
        if !uiState.isExpanded {
            expand()
        }
        uiState.selectedTab = .files
    }

    private func expand() {
        panel.setFrame(NotchGeometry.expandedFrame(), display: true)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            uiState.isExpanded = true
        }
        panel.makeKey()
        effectView.layer?.cornerRadius = Self.expandedCornerRadius
        effectView.isHidden = false
        // SwiftUI может домонтировать AppKit-вью (NSTextView и т.п.) лениво при
        // первом реальном показе — повторяем снятие регистрации на всякий случай.
        hostingView.unregisterDraggedTypesRecursively()
    }

    private func handleMouseExited() {
        scheduleCollapseCheck(after: Self.collapseDelay)
    }

    private func scheduleCollapseCheck(after delay: TimeInterval) {
        collapseWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.attemptCollapse()
        }
        collapseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    /// Не сворачиваем, пока фокус ввода — в текстовом поле (переводчик/таймер) И
    /// панель при этом ключевая, иначе панель схлопывается прямо во время печати.
    /// Field editor у TextField и текстовый движок под TextEditor — оба NSTextView.
    /// `isKeyWindow` обязателен: клик в другое приложение оставляет field editor
    /// "застрявшим" firstResponder навсегда — без этого условия проверка
    /// перепланировалась бы бесконечно и панель никогда не сворачивалась.
    private func attemptCollapse() {
        guard panel.isKeyWindow, panel.firstResponder is NSTextView else {
            collapse()
            return
        }
        scheduleCollapseCheck(after: Self.focusRecheckDelay)
    }

    private func collapse() {
        // Сбрасывает застрявший фокус (field editor), чтобы следующий цикл
        // проверки фокуса начинался чисто.
        panel.makeFirstResponder(nil)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            uiState.isExpanded = false
        }
        effectView.isHidden = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.collapseAnimationDuration) { [weak self] in
            guard let self, self.uiState.isExpanded == false else { return }
            self.panel.setFrame(NotchGeometry.collapsedFrame(), display: true)
        }
    }

    @objc private func windowDidResignKey() {
        guard uiState.isExpanded, !panel.frame.contains(NSEvent.mouseLocation) else { return }
        scheduleCollapseCheck(after: 0)
    }

    @objc private func screenParametersChanged() {
        uiState.topInset = NotchGeometry.notchHeight()
        let frame = uiState.isExpanded ? NotchGeometry.expandedFrame() : NotchGeometry.collapsedFrame()
        panel.setFrame(frame, display: true)
    }
}
