import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import FinderSync

/// Системные разрешения, которые нужны Northy, и как узнать их состояние.
enum Permission: CaseIterable, Identifiable {
    case fullDiskAccess, screenRecording, microphone, accessibility, finderExtension, keychain

    enum State: Equatable {
        case granted, denied, unknown
        /// Системной проверки нет (Связка ключей: macOS спрашивает сама).
        case notChecked
    }

    var id: Self { self }

    var title: String {
        switch self {
        case .fullDiskAccess: "Полный доступ к диску"
        case .screenRecording: "Запись экрана"
        case .microphone: "Микрофон"
        case .accessibility: "Универсальный доступ"
        case .finderExtension: "Расширение Finder"
        case .keychain: "Связка ключей"
        }
    }

    var purpose: String {
        switch self {
        case .fullDiskAccess: "Нужен лимитам Claude: чтение cookies Safari."
        case .screenRecording: "Нужна вкладке «Инструменты»: снимки, текст с экрана, запись. После включения перезапустите Northy."
        case .microphone: "Нужен записи экрана со звуком с микрофона."
        case .accessibility: "Нужен плитке „Скрипт“: нажатия клавиш из запущенного скрипта."
        case .finderExtension: "Действия Northy в контекстном меню Finder; включается в Системных настройках."
        case .keychain: "Хранит ключ Z.AI. Отдельного переключателя нет: macOS спрашивает сама, после переустановки Northy — заново."
        }
    }

    var hasSettingsAction: Bool { self != .keychain }

    func state(_ checks: PermissionChecks) -> State {
        switch self {
        case .fullDiskAccess:
            switch checks.fullDiskAccess() {
            case .granted: .granted
            case .denied: .denied
            case .unknown: .unknown
            }
        case .screenRecording: checks.screenRecording() ? .granted : .denied
        case .microphone:
            switch checks.microphone() {
            case .authorized: .granted
            case .notDetermined: .unknown
            default: .denied
            }
        case .accessibility: checks.accessibility() ? .granted : .denied
        case .finderExtension: checks.finderExtension() ? .granted : .denied
        case .keychain: .notChecked
        }
    }

    func openSettings(_ checks: PermissionChecks) {
        guard hasSettingsAction else { return }
        checks.open(self)
    }
}

/// Подменяемые проверки: по умолчанию только чтение состояния, без системных запросов.
struct PermissionChecks {
    var fullDiskAccess: () -> FullDiskAccess.Status = { FullDiskAccess.status() }
    var screenRecording: () -> Bool = { CGPreflightScreenCaptureAccess() }
    var finderExtension: () -> Bool = { FIFinderSyncController.isExtensionEnabled }
    var microphone: () -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for: .audio) }
    var accessibility: () -> Bool = { AXIsProcessTrusted() }
    /// Не вызывается при пересчёте состояний; нужен, чтобы тест мог это проверить.
    var requestScreenRecording: () -> Void = { _ = CGRequestScreenCaptureAccess() }
    var open: (Permission) -> Void = { permission in
        switch permission {
        case .fullDiskAccess: NSWorkspace.shared.open(FullDiskAccess.settingsURL)
        case .screenRecording: NSWorkspace.shared.open(ScreenCapture.settingsURL)
        case .microphone: NSWorkspace.shared.open(ScreenRecorder.microphoneSettingsURL)
        case .accessibility: NSWorkspace.shared.open(ScriptRunner.settingsURL)
        case .finderExtension: FIFinderSyncController.showExtensionManagementInterface()
        case .keychain: break
        }
    }
}
