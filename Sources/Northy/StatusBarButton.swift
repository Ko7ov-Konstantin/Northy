import Foundation

/// Что показывает значок Northy в строке меню: строки остатка; пусто — знак Northy.
enum StatusBarButton {
    static func lines(activity: ToolsStore.Activity, limits: [String]) -> [String] {
        switch activity {
        case .recording, .finishing: []
        case .idle, .capturing, .pickingColor: limits
        }
    }

    /// Отдельный значок «стоп»: nil — скрыт, false — виден, но файл ещё дописывается.
    static func stopItem(activity: ToolsStore.Activity) -> Bool? {
        switch activity {
        case .recording: true
        case .finishing: false
        case .idle, .capturing, .pickingColor: nil
        }
    }
}
