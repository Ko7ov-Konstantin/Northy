import AppKit

/// Геометрия выделения области экрана. Координаты — точки, начало слева сверху (как у SCK).
nonisolated enum AreaSelection {
    /// Прямоугольник выделения в точках с началом в левом верхнем углу экрана; nil — выделение слишком мало.
    static func rect(from start: CGPoint, to end: CGPoint, screenHeight: CGFloat) -> CGRect? {
        let width = abs(end.x - start.x).rounded()
        let height = abs(end.y - start.y).rounded()
        guard width >= 16, height >= 16 else { return nil }
        return CGRect(
            x: min(start.x, end.x).rounded(),
            y: (screenHeight - max(start.y, end.y)).rounded(),
            width: width,
            height: height
        )
    }

    /// Размер кадра в пикселях: H.264 требует чётных сторон.
    static func pixelSize(_ size: CGSize, scale: CGFloat) -> (width: Int, height: Int) {
        (even(Int((size.width * scale).rounded())), even(Int((size.height * scale).rounded())))
    }

    /// Место кнопки в координатах вида: по центру под выделением, а если снизу нет места — внутри него.
    static func startButtonOrigin(below hole: CGRect, size: CGSize, in bounds: CGRect) -> CGPoint {
        let below = hole.minY - 12 - size.height
        let x = min(max(hole.midX - size.width / 2, bounds.minX + 8), bounds.maxX - 8 - size.width)
        return CGPoint(x: x, y: below < bounds.minY + 8 ? hole.minY + 12 : below)
    }

    private static func even(_ value: Int) -> Int {
        max(2, value - value % 2)
    }
}

/// Затемнённый основной экран, в котором мышью выделяют область.
enum AreaPicker {
    /// nil — выбор отменён (Esc).
    static func pick() async -> CGRect? {
        guard let screen = NSScreen.screens.first else { return nil }
        return await withCheckedContinuation { continuation in
            let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            let window = presentDimmedScreen(view, screen: screen)
            // Окно держит вид, вид — замыкание: после завершения замыкание снимается, цикла не остаётся.
            view.onFinish = { rect in
                window.orderOut(nil)
                continuation.resume(returning: rect)
            }
        }
    }
}

/// Показывает затемняемый экран поверх всего; вид получает мышь и клавиши.
func presentDimmedScreen(_ view: NSView, screen: NSScreen) -> SelectionWindow {
    let window = SelectionWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.level = .screenSaver
    // Показ на текущем рабочем столе, в том числе поверх полноэкранного приложения.
    window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    window.isOpaque = false
    window.backgroundColor = .clear
    window.ignoresMouseEvents = false
    window.contentView = view
    NSApp.activate()
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(view)
    return window
}

/// Затемнение всего вида; hole — светлое окно «дыра» с белой рамкой.
func drawDimming(in bounds: NSRect, hole: NSRect?) {
    let dim = NSBezierPath(rect: bounds)
    if let hole {
        dim.append(NSBezierPath(rect: hole))
        dim.windingRule = .evenOdd
    }
    NSColor.black.withAlphaComponent(0.35).setFill()
    dim.fill()
    if let hole {
        let frame = NSBezierPath(rect: hole.insetBy(dx: 0.5, dy: 0.5))
        frame.lineWidth = 1
        NSColor.white.setStroke()
        frame.stroke()
    }
}

/// Кнопка «Начать запись»: скрыта, пока нет выделения; Enter нажимает её.
func makeStartButton(target: AnyObject, action: Selector) -> NSButton {
    let button = NSButton(title: "Начать запись", target: target, action: action)
    button.keyEquivalent = "\r"
    button.isHidden = true
    button.sizeToFit()
    return button
}

/// Ставит кнопку под выделением; без выделения прячет.
func placeStartButton(_ button: NSButton, below hole: NSRect?, in view: NSView) {
    if button.superview == nil { view.addSubview(button) }
    button.isHidden = hole == nil
    guard let hole else { return }
    button.setFrameOrigin(AreaSelection.startButtonOrigin(below: hole, size: button.frame.size, in: view.bounds))
}

/// Без рамки окно не становится ключевым, а Esc приходит только ключевому окну.
final class SelectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

final class SelectionView: NSView {
    /// Выбор завершён: область или nil (Esc); вызывается один раз.
    var onFinish: ((CGRect?) -> Void)?
    private var start: CGPoint?
    private var current: CGPoint?
    private(set) lazy var startButton = makeStartButton(target: self, action: #selector(confirm))

    override var acceptsFirstResponder: Bool { true }

    private var hole: CGRect? {
        guard let start, let current else { return nil }
        return CGRect(origin: start, size: CGSize(width: current.x - start.x, height: current.y - start.y)).standardized
    }

    override func draw(_ dirtyRect: NSRect) {
        drawDimming(in: bounds, hole: hole)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        current = start
        placeStartButton(startButton, below: nil, in: self)
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        // Случайный клик без выделения ничего не выбирает.
        if selection == nil { start = nil }
        placeStartButton(startButton, below: hole, in: self)
        needsDisplay = true
    }

    private var selection: CGRect? {
        guard let start, let current else { return nil }
        return AreaSelection.rect(from: start, to: current, screenHeight: bounds.height)
    }

    @objc private func confirm() {
        if let selection { finish(selection) }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { finish(nil) }
    }

    private func finish(_ rect: CGRect?) {
        let done = onFinish
        onFinish = nil
        done?(rect)
    }
}
