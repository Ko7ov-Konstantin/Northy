import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let panelController = PanelController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = EditMenu.make()
        panelController.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Отложенные debounced-записи истории и полки — на диск немедленно,
    /// иначе последние изменения потеряются при выходе.
    func applicationWillTerminate(_ notification: Notification) {
        panelController.flushStores()
    }
}
