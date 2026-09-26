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

/// Кнопка «Поделиться» (AirDrop, Сообщения, Почта…). Системному меню нужна
/// AppKit-вью, от которой его показать, — это невидимый якорь позади обычной
/// IconButton: у NSButton наведением и курсором владеет AppKit, подсветки не было бы.
struct ShareButton: View {
    let url: URL
    var size: CGFloat = 20

    @State private var anchor = SharingAnchor()

    var body: some View {
        IconButton(systemName: "square.and.arrow.up", size: size, help: "Поделиться — AirDrop и другие") {
            anchor.share(url)
        }
        .background(SharingAnchorView(anchor: anchor).allowsHitTesting(false))
    }
}

@MainActor
final class SharingAnchor {
    weak var view: NSView?

    func share(_ url: URL) {
        guard let view else { return }
        NSSharingServicePicker(items: [url]).show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }
}

private final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct SharingAnchorView: NSViewRepresentable {
    let anchor: SharingAnchor

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
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
