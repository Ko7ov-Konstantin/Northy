import Cocoa
import FinderSync

/// Пункты Northy в контекстном меню Finder: «Отправить в Northy» и, если на
/// полку что-то попало за последние 10 минут, «Вставить из Northy».
///
/// Расширение живёт в песочнице: читает только файл состояния Northy
/// (~/Library/Application Support/Northy/finder-bridge.json — исключение
/// в entitlements) и шлёт команды distributed-уведомлением. Файлы копирует сам
/// Northy. Нет файла состояния — Northy не запущен, пунктов нет.
@objc(FinderSync)
final class FinderSync: FIFinderSync {
    private static let requestName = Notification.Name("com.kotov.northy.finder.request")
    private static let recentWindow: TimeInterval = 10 * 60

    private struct State: Decodable {
        struct Item: Decodable {
            let path: String
            let name: String
            let addedAt: Double
        }
        let token: String
        let recent: [Item]
    }

    override init() {
        super.init()
        // Меню нужны везде — следим за всем диском (только за меню, не за файлами).
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    /// В песочнице NSHomeDirectory() — контейнер расширения; настоящий дом — из passwd.
    private static var stateURL: URL {
        let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support/Northy/finder-bridge.json")
    }

    private func loadState() -> State? {
        guard let data = try? Data(contentsOf: Self.stateURL) else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    private func recentItems(in state: State) -> [State.Item] {
        let now = Date().timeIntervalSince1970
        return state.recent.filter { now - $0.addedAt <= Self.recentWindow }
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems || menuKind == .contextualMenuForContainer,
              let state = loadState()
        else { return nil }
        let menu = NSMenu(title: "")

        if menuKind == .contextualMenuForItems,
           let selected = FIFinderSyncController.default().selectedItemURLs(), !selected.isEmpty {
            let item = NSMenuItem(title: "Отправить в Northy", action: #selector(sendToNorthy(_:)), keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "tray.and.arrow.down", accessibilityDescription: nil)
            menu.addItem(item)
        }

        let recent = recentItems(in: state)
        if !recent.isEmpty {
            let title = recent.count == 1
                ? "Вставить из Northy: \(recent[0].name)"
                : "Вставить из Northy (\(Self.filesCount(recent.count)))"
            let item = NSMenuItem(title: title, action: #selector(pasteFromNorthy(_:)), keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
            menu.addItem(item)
        }
        return menu.items.isEmpty ? nil : menu
    }

    /// «2 файла», «5 файлов», «21 файл».
    private static func filesCount(_ count: Int) -> String {
        let n = count % 100, last = n % 10
        let word = (11...14).contains(n) ? "файлов" : last == 1 ? "файл" : (2...4).contains(last) ? "файла" : "файлов"
        return "\(count) \(word)"
    }

    @IBAction func sendToNorthy(_ sender: AnyObject?) {
        guard let urls = FIFinderSyncController.default().selectedItemURLs(), !urls.isEmpty else { return }
        post(action: "send", paths: urls.map(\.path))
    }

    /// Правый клик по одной папке — вставка в неё, иначе — в папку, где кликнули.
    @IBAction func pasteFromNorthy(_ sender: AnyObject?) {
        let controller = FIFinderSyncController.default()
        var target = controller.targetedURL()
        if let selected = controller.selectedItemURLs(), selected.count == 1, selected[0].hasDirectoryPath {
            target = selected[0]
        }
        guard let target else { return }
        post(action: "paste", paths: [target.path])
    }

    /// userInfo из песочницы не доставляется — вся команда уходит строкой в object.
    private func post(action: String, paths: [String]) {
        guard let state = loadState() else { return }
        let payload: [String: Any] = ["token": state.token, "action": action, "paths": paths]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8)
        else { return }
        DistributedNotificationCenter.default().postNotificationName(
            Self.requestName,
            object: json,
            userInfo: nil,
            deliverImmediately: true
        )
    }
}
