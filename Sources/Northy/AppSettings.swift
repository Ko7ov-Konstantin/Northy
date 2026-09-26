import Foundation
import Observation

/// Настройки приложения в UserDefaults. Меняются из окна настроек, читаются
/// контроллером панели и сторами.
@MainActor
@Observable
final class AppSettings {
    static let clipboardLimits = [50, 100, 300, 1000]

    @ObservationIgnored private let defaults: UserDefaults

    /// Сочетание для открытия панели с клавиатуры.
    var hotKey: HotKeyPreset {
        didSet { defaults.set(hotKey.rawValue, forKey: Keys.hotKey) }
    }

    /// Разворачивать панель при наведении на вырез (иначе — только клавишей и из меню).
    var openOnHover: Bool {
        didSet { defaults.set(openOnHover, forKey: Keys.openOnHover) }
    }

    /// Сколько записей хранит история буфера (закреплённые — сверх лимита).
    var clipboardLimit: Int {
        didSet { defaults.set(clipboardLimit, forKey: Keys.clipboardLimit) }
    }

    /// Какие вкладки показывать; «Буфер» включён всегда.
    var enabledTabs: Set<PanelTab> {
        didSet {
            if !enabledTabs.contains(.clipboard) { enabledTabs.insert(.clipboard) }
            let saved = enabledTabs.union([.clipboard])
            defaults.set(PanelTab.allCases.filter(saved.contains).map(\.rawValue), forKey: Keys.enabledTabs)
        }
    }

    /// Почему сочетание не назначилось (занято и т. п.); nil — всё в порядке. Не сохраняется.
    var hotKeyProblem: String?

    private enum Keys {
        static let hotKey = "hotkey.preset"
        static let openOnHover = "panel.openOnHover"
        static let clipboardLimit = "clipboard.limit"
        static let enabledTabs = "panel.enabledTabs"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hotKey = defaults.string(forKey: Keys.hotKey).flatMap(HotKeyPreset.init(rawValue:)) ?? .optionSpace
        openOnHover = defaults.object(forKey: Keys.openOnHover) as? Bool ?? true
        let limit = defaults.integer(forKey: Keys.clipboardLimit)
        clipboardLimit = Self.clipboardLimits.contains(limit) ? limit : 100
        if let stored = defaults.stringArray(forKey: Keys.enabledTabs) {
            enabledTabs = Set(stored.compactMap(PanelTab.init(rawValue:))).union([.clipboard])
        } else {
            // По умолчанию — только «Буфер»; остальное включается в настройках.
            enabledTabs = [.clipboard]
        }
    }
}
