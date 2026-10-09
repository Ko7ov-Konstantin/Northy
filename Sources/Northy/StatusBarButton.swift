import Foundation

/// Что показывает значок Northy в строке меню: строки остатка; пусто — знак Northy.
enum StatusBarButton {
    static func lines(activity: ToolsStore.Activity, limits: [String]) -> [String] {
        switch activity {
        case .recording, .finishing: []
        case .idle, .capturing, .pickingColor: limits
        }
    }
}
