import AppKit

/// Безрамочная плавающая панель поверх выреза. canBecomeKey переопределён,
/// иначе TextField переводчика не сможет получить фокус ввода.
final class NotchPanel: NSPanel {

    /// Escape сворачивает панель. performKeyEquivalent приходит, только пока
    /// панель ключевая — развёрнутая через hover панель как раз ключ (expand → makeKey).
    var onEscape: (() -> Void)?

    init(contentRect: CGRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        // .screenSaver (1000) исключал окно из drag-целей window server'а — дроп
        // не принимался вовсе (ни draggingEntered, ни exited). .popUpMenu (101) всё ещё
        // выше statusBar (25) и обычных окон, но участвует в drag-сессиях.
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53, let onEscape {
            onEscape()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
