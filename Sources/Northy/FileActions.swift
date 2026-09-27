import AppKit
import Quartz
import SwiftUI

/// Быстрый просмотр — системная панель Quick Look. Получает весь набор (картинки
/// буфера, файлы полки) и открывается на выбранном: дальше листается стрелками.
@MainActor
final class QuickLook: NSObject, @preconcurrency QLPreviewPanelDataSource {
    static let shared = QuickLook()

    private var urls: [URL] = []
    private(set) var startIndex = 0

    func prepare(_ urls: [URL], startingAt url: URL) {
        self.urls = urls
        startIndex = urls.firstIndex(of: url) ?? 0
    }

    func show(_ url: URL, among urls: [URL]? = nil) {
        prepare(urls ?? [url], startingAt: url)
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.currentPreviewItemIndex = startIndex
        // Accessory-приложение без активации не получит в панель фокус (стрелки, пробел).
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        // Панель у выреза висит на уровне .popUpMenu — просмотр поверх неё. Quick Look
        // выставляет свой уровень при показе, поэтому поднимаем после.
        DispatchQueue.main.async {
            panel.level = NSWindow.Level(NSWindow.Level.popUpMenu.rawValue + 1)
            panel.orderFrontRegardless()
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        urls.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        urls.indices.contains(index) ? urls[index] as NSURL : nil
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
