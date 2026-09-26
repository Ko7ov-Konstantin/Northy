import AppKit
import SwiftUI

/// «Полный доступ к диску» нужен лимитам: без него cookies Safari не прочитать.
/// Проверка — попытка открыть файл cookies (сам файл не читается целиком).
nonisolated enum FullDiskAccess {
    enum Status: Equatable {
        case granted, denied
        /// Проверять нечем (Safari не запускали) — пользователя не дёргаем.
        case unknown
    }

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    static var probeFiles: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            "Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies",
            "Library/Cookies/Cookies.binarycookies",
        ].map { home.appendingPathComponent($0) }
    }

    static func status(probing files: [URL] = probeFiles, open: (URL) throws -> Void = { try FileHandle(forReadingFrom: $0).close() }) -> Status {
        var denied = false
        for url in files {
            do {
                try open(url)
                return .granted
            } catch let error as NSError {
                let noPermission = (error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError)
                    || (error.domain == NSPOSIXErrorDomain && (error.code == Int(EPERM) || error.code == Int(EACCES)))
                if noPermission { denied = true }
            }
        }
        return denied ? .denied : .unknown
    }
}

/// Помощник поверх Системных настроек: значок Northy, который можно перетащить в
/// список, и подсказка. Раз в секунду проверяет доступ и закрывается сам.
@MainActor
final class DiskAccessGuide {
    private var panel: NSPanel?
    private var timer: Timer?
    private let model = Model()
    var onGranted: (() -> Void)?

    @Observable
    final class Model {
        var isGranted = false
    }

    func start() {
        NSWorkspace.shared.open(FullDiskAccess.settingsURL)
        model.isGranted = false
        show()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    private func check() {
        guard FullDiskAccess.status() == .granted, !model.isGranted else { return }
        withAnimation(Theme.tabSpring) { model.isGranted = true }
        timer?.invalidate()
        onGranted?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in self?.close() }
    }

    func close() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
    }

    private func show() {
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 360, height: 150),
                styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel, .utilityWindow],
                backing: .buffered,
                defer: false
            )
            panel.titlebarAppearsTransparent = true
            panel.titleVisibility = .hidden
            panel.isMovableByWindowBackground = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.contentView = NSHostingView(rootView: DiskAccessGuideView(model: model) { [weak self] in
                self?.close()
            })
            self.panel = panel
        }
        guard let panel, let screen = NSScreen.main?.visibleFrame else { return }
        // Правее центра экрана, внизу — рядом с окном Системных настроек, не поверх списка.
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: screen.midX + 180, y: screen.minY + 80))
        panel.setContentSize(size)
        panel.orderFrontRegardless()
    }
}

struct DiskAccessGuideView: View {
    var model: DiskAccessGuide.Model
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // Значок перетаскивается в список «Полный доступ к диску», если Northy там нет.
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .onDrag { NSItemProvider(object: Bundle.main.bundleURL as NSURL) }
                .help("Перетащите в список «Полный доступ к диску»")
            VStack(alignment: .leading, spacing: 6) {
                if model.isGranted {
                    Label("Доступ есть — лимиты подтянутся", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.green)
                        .transition(.opacity)
                } else {
                    Text("Разрешите Northy полный доступ к диску")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Включите переключатель у Northy в списке. Нет в списке — перетащите этот значок в окно настроек.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Открыть настройки снова") { NSWorkspace.shared.open(FullDiskAccess.settingsURL) }
                        Button("Позже", action: onClose)
                    }
                    .controlSize(.small)
                    .padding(.top, 2)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 26)
        .padding(.bottom, 16)
        .frame(width: 360, alignment: .leading)
    }
}
