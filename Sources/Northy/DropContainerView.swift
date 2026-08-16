import AppKit

/// Прозрачный для кликов оверлей поверх всей панели, зарегистрированный на приём
/// файлов. SwiftUI-путь (.onDrop/.dropDestination) в nonactivating borderless
/// NSPanel из accessory-приложения ненадёжен — курсор дропа остаётся «нельзя» —
/// поэтому дроп принимается классическим AppKit NSDraggingDestination. hitTest
/// возвращает nil, поэтому клики и жесты проходят сквозь оверлей к SwiftUI-контенту
/// под ним; поиск drop-цели идёт не через hitTest, а по registered types и геометрии,
/// так что это не мешает получать draggingEntered/performDragOperation.
final class DropContainerView: NSView {
    var onFileURLs: (([URL]) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Плавающая миниатюра скриншота — не file URL, а file promise
    /// (NSFilePromiseReceiver): реальный файл появляется только после
    /// receivePromisedFiles, поэтому ему нужна постоянная папка-приёмник.
    private let dropsDirectory = DropContainerView.makeDropsDirectory()
    private let promiseQueue = OperationQueue()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let promiseTypes = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        registerForDraggedTypes([.fileURL] + promiseTypes)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func makeDropsDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Northy/Drops", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            // Без этой папки file promise принять нельзя — оставляем след в логе
            // вместо молчаливой потери дропа.
            NSLog("[Northy] Drops directory creation failed: %@", error.localizedDescription)
        }
        return dir
    }

    private func canAcceptDrag(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        let hasFileURL = pasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        )
        let hasPromise = pasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil)
        return hasFileURL || hasPromise
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        canAcceptDrag(sender) ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        canAcceptDrag(sender) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard

        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            onFileURLs?(urls)
            return true
        }

        if let receivers = pasteboard.readObjects(
            forClasses: [NSFilePromiseReceiver.self],
            options: nil
        ) as? [NSFilePromiseReceiver], !receivers.isEmpty {
            for receiver in receivers {
                receiver.receivePromisedFiles(
                    atDestination: dropsDirectory,
                    options: [:],
                    operationQueue: promiseQueue
                ) { [weak self] url, error in
                    if let error {
                        NSLog("[Northy] file promise receive failed: %@", error.localizedDescription)
                        return
                    }
                    Task { @MainActor in
                        self?.onFileURLs?([url])
                    }
                }
            }
            return true
        }

        return false
    }
}
