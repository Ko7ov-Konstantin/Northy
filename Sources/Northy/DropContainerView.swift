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
    /// true — над панелью тащат принимаемый файл (для подсветки зоны дропа).
    var onTargetingChanged: ((Bool) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Плавающая миниатюра скриншота — не file URL, а file promise
    /// (NSFilePromiseReceiver): реальный файл появляется только после
    /// receivePromisedFiles, поэтому ему нужна постоянная папка-приёмник.
    private let dropsDirectory = AppData.dropsDirectory
    private let promiseQueue = OperationQueue()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let promiseTypes = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        registerForDraggedTypes([.fileURL] + promiseTypes)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
        let accepts = canAcceptDrag(sender)
        onTargetingChanged?(accepts)
        return accepts ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onTargetingChanged?(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onTargetingChanged?(false)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        canAcceptDrag(sender) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onTargetingChanged?(false)
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
            // Своя подпапка на drag-сессию: одинаковые имена обещанных файлов
            // (типичный случай — скриншоты) иначе перезаписывают друг друга.
            let sessionDirectory = dropsDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
            } catch {
                NSLog("[Northy] drops session directory creation failed: %@", error.localizedDescription)
                return false
            }
            for receiver in receivers {
                receiver.receivePromisedFiles(
                    atDestination: sessionDirectory,
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
