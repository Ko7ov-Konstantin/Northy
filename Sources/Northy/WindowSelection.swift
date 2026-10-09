import AppKit

/// Окно на экране: рамка — в точках, начало в левом верхнем углу основного дисплея (как отдаёт CGWindowList).
nonisolated struct ScreenWindow: Equatable, Sendable {
    let id: CGWindowID
    let frame: CGRect
    let layer: Int
    let ownerPID: pid_t
}

nonisolated enum WindowSelection {
    /// Верхнее обычное окно под точкой; windows — в порядке от переднего к заднему.
    static func window(at point: CGPoint, in windows: [ScreenWindow], excludingPID: pid_t) -> ScreenWindow? {
        windows.first { window in
            window.layer == 0
                && window.ownerPID != excludingPID
                && window.frame.width >= 40 && window.frame.height >= 40
                && window.frame.contains(point)
        }
    }

    /// Рамка окна в координатах вида AppKit (начало слева снизу).
    static func viewRect(for frame: CGRect, screenHeight: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: screenHeight - frame.maxY, width: frame.width, height: frame.height)
    }
}

/// Затемнённый основной экран, в котором кликом выбирают окно под курсором.
enum WindowPicker {
    /// nil — выбор отменён (Esc).
    static func pick() async -> CGWindowID? {
        guard let screen = NSScreen.screens.first else { return nil }
        return await withCheckedContinuation { continuation in
            let view = WindowSelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            let window = presentDimmedScreen(view, screen: screen)
            // Список читается один раз, когда затемнение уже на экране: всё под ним — кандидаты.
            view.windows = onScreenWindows(below: CGWindowID(window.windowNumber))
            view.pointer = window.mouseLocationOutsideOfEventStream
            view.onFinish = { id in
                window.orderOut(nil)
                continuation.resume(returning: id)
            }
        }
    }

    /// Окна под затемнением от переднего к заднему; записи без нужных полей пропускаются.
    private static func onScreenWindows(below windowNumber: CGWindowID) -> [ScreenWindow] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenBelowWindow, .excludeDesktopElements], windowNumber) as? [[String: Any]] ?? []
        return info.compactMap(screenWindow(from:))
    }

    private static func screenWindow(from info: [String: Any]) -> ScreenWindow? {
        guard let id = info[kCGWindowNumber as String] as? CGWindowID,
              let bounds = info[kCGWindowBounds as String] as? [String: Any],
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
              let layer = info[kCGWindowLayer as String] as? Int,
              let pid = info[kCGWindowOwnerPID as String] as? pid_t
        else { return nil }
        return ScreenWindow(id: id, frame: frame, layer: layer, ownerPID: pid)
    }
}

final class WindowSelectionView: NSView {
    /// Выбор завершён: id окна или nil (Esc); вызывается один раз.
    var onFinish: ((CGWindowID?) -> Void)?
    var windows: [ScreenWindow] = []
    /// Курсор в координатах вида (начало слева снизу).
    var pointer: CGPoint?
    /// Окно, выбранное кликом: ждёт кнопки «Начать запись».
    private var selected: ScreenWindow?
    private(set) lazy var startButton = makeStartButton(target: self, action: #selector(confirm))

    override var acceptsFirstResponder: Bool { true }

    private var hovered: ScreenWindow? {
        guard let pointer else { return nil }
        // Рамки окон приходят с началом сверху, поэтому точку переворачиваем.
        let point = CGPoint(x: pointer.x, y: bounds.height - pointer.y)
        return WindowSelection.window(at: point, in: windows, excludingPID: ProcessInfo.processInfo.processIdentifier)
    }

    override func draw(_ dirtyRect: NSRect) {
        drawDimming(in: bounds, hole: viewRect(of: selected ?? hovered))
    }

    private func viewRect(of window: ScreenWindow?) -> NSRect? {
        window.map { WindowSelection.viewRect(for: $0.frame, screenHeight: bounds.height) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseMoved(with event: NSEvent) {
        pointer = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        pointer = convert(event.locationInWindow, from: nil)
        selected = hovered
        placeStartButton(startButton, below: viewRect(of: selected), in: self)
        needsDisplay = true
    }

    @objc private func confirm() {
        if let selected { finish(selected.id) }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { finish(nil) }
    }

    private func finish(_ id: CGWindowID?) {
        let done = onFinish
        onFinish = nil
        done?(id)
    }
}
