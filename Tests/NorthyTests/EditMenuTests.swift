import AppKit
import Testing
@testable import Northy

@MainActor
/// Без пунктов «Правки» в главном меню ⌘V и соседи не доходят до полей ввода.
struct EditMenuTests {

    @Test func editShortcutsReachTextFields() throws {
        let edit = try #require(EditMenu.make().items.first?.submenu)
        let shortcuts = edit.items.filter { !$0.isSeparatorItem }.map {
            "\($0.keyEquivalentModifierMask.contains(.shift) ? "⇧" : "")⌘\($0.keyEquivalent) \($0.action.map(NSStringFromSelector) ?? "-")"
        }

        #expect(shortcuts == ["⌘z undo:", "⇧⌘z redo:", "⌘x cut:", "⌘c copy:", "⌘v paste:", "⌘a selectAll:"])
        #expect(edit.items.allSatisfy { $0.target == nil }, "действие уходит в поле с курсором")
    }
}
