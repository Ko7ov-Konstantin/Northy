import AppKit

/// Обратный отсчёт перед записью по центру основного экрана.
enum RecordingCountdown {
    static let seconds = 3

    /// true — начинать запись (отсчёт дошёл до нуля или пропущен); false — отменено (Esc).
    static func run() async -> Bool {
        guard let screen = NSScreen.screens.first else { return true }
        let view = CountdownView(frame: NSRect(origin: .zero, size: screen.frame.size))
        let window = presentDimmedScreen(view, screen: screen)
        // Окно отсчёта убирается до старта, чтобы не попасть в кадр.
        defer { window.orderOut(nil) }
        return await view.run(from: seconds)
    }
}

final class CountdownView: NSView {
    private static let plate = CGSize(width: 280, height: 190)

    let number = NSTextField(labelWithString: "")
    private(set) lazy var skipButton = NSButton(title: "Пропустить", target: self, action: #selector(skip))
    private(set) lazy var cancelButton = NSButton(title: "Отменить", target: self, action: #selector(cancel))
    private var onFinish: ((Bool) -> Void)?
    private var ticking: Task<Void, Never>?

    override var acceptsFirstResponder: Bool { true }

    private var plateRect: NSRect {
        NSRect(x: bounds.midX - Self.plate.width / 2, y: bounds.midY - Self.plate.height / 2, width: Self.plate.width, height: Self.plate.height)
    }

    func run(from seconds: Int, tick: Duration = .seconds(1)) async -> Bool {
        addContent()
        return await withCheckedContinuation { continuation in
            onFinish = { continuation.resume(returning: $0) }
            ticking = Task {
                for left in stride(from: seconds, to: 0, by: -1) {
                    number.stringValue = String(left)
                    try? await Task.sleep(for: tick)
                    if Task.isCancelled { return }
                }
                finish(true)
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: plateRect, xRadius: 28, yRadius: 28).fill()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { finish(false) }
    }

    @objc private func skip() {
        finish(true)
    }

    @objc private func cancel() {
        finish(false)
    }

    private func addContent() {
        // Плашка тёмная при любой теме системы — кнопкам нужен светлый текст.
        appearance = NSAppearance(named: .darkAqua)
        number.font = .monospacedDigitSystemFont(ofSize: 96, weight: .bold)
        number.textColor = .white
        number.alignment = .center
        number.frame = NSRect(x: plateRect.minX, y: plateRect.minY + 58, width: plateRect.width, height: 116)
        skipButton.keyEquivalent = "\r"
        skipButton.sizeToFit()
        cancelButton.sizeToFit()
        let gap: CGFloat = 12
        let left = plateRect.midX - (cancelButton.frame.width + gap + skipButton.frame.width) / 2
        cancelButton.setFrameOrigin(NSPoint(x: left, y: plateRect.minY + 18))
        skipButton.setFrameOrigin(NSPoint(x: left + cancelButton.frame.width + gap, y: plateRect.minY + 18))
        addSubview(number)
        addSubview(cancelButton)
        addSubview(skipButton)
    }

    private func finish(_ start: Bool) {
        ticking?.cancel()
        let done = onFinish
        onFinish = nil
        done?(start)
    }
}
