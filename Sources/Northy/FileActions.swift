import AppKit
import Quartz
import SwiftUI

/// Быстрый просмотр файла с полки — системная панель Quick Look.
@MainActor
final class QuickLook: NSObject, @preconcurrency QLPreviewPanelDataSource {
    static let shared = QuickLook()

    private var url: URL?

    func show(_ url: URL) {
        self.url = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        // Accessory-приложение без активации не получит в панель фокус (стрелки, пробел).
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        url == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        url as NSURL?
    }
}

/// Кнопка «Поделиться» (AirDrop, Сообщения, Почта…): системному меню нужна
/// AppKit-вью, от которой его показать, поэтому кнопка — обёртка над NSButton.
struct ShareButton: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            image: NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Поделиться") ?? NSImage(),
            target: context.coordinator,
            action: #selector(Coordinator.share(_:))
        )
        button.isBordered = false
        button.imageScaling = .scaleProportionallyDown
        button.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        button.contentTintColor = NSColor.white.withAlphaComponent(0.75)
        button.toolTip = "Поделиться — AirDrop и другие"
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.url = url
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    @MainActor
    final class Coordinator: NSObject {
        var url: URL

        init(url: URL) {
            self.url = url
        }

        @objc func share(_ sender: NSButton) {
            NSSharingServicePicker(items: [url]).show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }
}

enum FileActions {
    /// Путь файла — в буфер обмена (и, значит, в историю буфера).
    @MainActor
    static func copyPath(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.path, forType: .string)
    }
}
