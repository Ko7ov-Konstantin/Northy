import Carbon.HIToolbox
import Foundation

/// Сочетания для открытия панели. Системные не используются: ⌃Space и ⌃⌥Space
/// переключают раскладку, ⌥⌘Space — поиск Finder, ⌥⌘N и ⇧⌘N — команды Finder.
enum HotKeyPreset: String, CaseIterable, Identifiable, Sendable {
    case optionSpace
    case optionGrave
    case controlOptionN
    case controlOptionCommandN
    case disabled

    var id: Self { self }

    var keyCode: UInt32 {
        switch self {
        case .optionSpace: UInt32(kVK_Space)
        case .optionGrave: UInt32(kVK_ANSI_Grave)
        case .controlOptionN, .controlOptionCommandN: UInt32(kVK_ANSI_N)
        case .disabled: 0
        }
    }

    var modifiers: UInt32 {
        switch self {
        case .optionSpace, .optionGrave: UInt32(optionKey)
        case .controlOptionN: UInt32(controlKey | optionKey)
        case .controlOptionCommandN: UInt32(controlKey | optionKey | cmdKey)
        case .disabled: 0
        }
    }

    var title: String {
        switch self {
        case .optionSpace: "⌥ Space"
        case .optionGrave: "⌥ `"
        case .controlOptionN: "⌃⌥ N"
        case .controlOptionCommandN: "⌃⌥⌘ N"
        case .disabled: "Выключена"
        }
    }
}

/// Глобальная горячая клавиша через Carbon RegisterEventHotKey — работает без
/// разрешения «Универсальный доступ», в отличие от мониторов клавиатуры.
@MainActor
final class GlobalHotKey {
    enum Failure: Error, Equatable {
        /// Сочетание уже занято другим приложением (Raycast, Alfred…).
        case taken
        case failed(OSStatus)
    }

    var onPress: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// Снимает прежнее сочетание и ставит новое; `.disabled` — только снимает.
    @discardableResult
    func register(_ preset: HotKeyPreset) -> Result<Void, Failure> {
        unregister()
        guard preset != .disabled else { return .success(()) }
        installHandlerIfNeeded()

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4E52_5459), id: 1) // 'NRTY'
        let status = RegisterEventHotKey(preset.keyCode, preset.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        switch status {
        case noErr:
            hotKeyRef = ref
            return .success(())
        case OSStatus(eventHotKeyExistsErr):
            return .failure(.taken)
        default:
            return .failure(.failed(status))
        }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            // Carbon доставляет событие в главном потоке.
            MainActor.assumeIsolated {
                Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue().onPress?()
            }
            return noErr
        }, 1, &spec, context, &handlerRef)
    }
}
