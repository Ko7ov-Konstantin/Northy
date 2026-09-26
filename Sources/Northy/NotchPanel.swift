import AppKit

/// Безрамочная плавающая панель поверх выреза. canBecomeKey переопределён,
/// иначе TextField переводчика не сможет получить фокус ввода.
final class NotchPanel: NSPanel {

    /// Escape сворачивает панель. performKeyEquivalent приходит, только пока
    /// панель ключевая — открытая панель под мышью ключевая (takeKeyForPointer).
    var onEscape: (() -> Void)?
    /// ⌘1…⌘9 — номер вкладки (с единицы), ⌘F — поиск в буфере.
    var onTabShortcut: ((Int) -> Void)?
    var onFind: (() -> Void)?
    var onSettings: (() -> Void)?

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

    /// По клику окно становится ключевым до диспетчеризации события — на случай,
    /// если панель открылась без мыши над ней (показ полки из Finder).
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, !isKeyWindow {
            makeKey()
        }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53, let onEscape {
            onEscape()
            return true
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command, let characters = event.charactersIgnoringModifiers {
            if let number = Int(characters), (1...9).contains(number), let onTabShortcut {
                onTabShortcut(number)
                return true
            }
            // keyCode 3 — клавиша F на любой раскладке (в русской это «А»).
            if event.keyCode == 3, let onFind {
                onFind()
                return true
            }
            // keyCode 43 — запятая (⌘, — настройки, как в любом приложении Mac).
            if event.keyCode == 43, let onSettings {
                onSettings()
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}
