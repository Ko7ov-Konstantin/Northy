import Carbon.HIToolbox
import Foundation
import Testing
@testable import Northy

@MainActor
/// Настройки приложения и горячая клавиша — на отдельном UserDefaults, не трогая реальные.
struct SettingsTests {

    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let suite = "NorthyTests-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    @Test func hotKeyPresetsAvoidSystemShortcuts() {
        let optionSpace = HotKeyPreset.optionSpace
        #expect(optionSpace.keyCode == UInt32(kVK_Space))
        #expect(optionSpace.modifiers == UInt32(optionKey))
        #expect(optionSpace.title == "⌥ Space")

        let combos = HotKeyPreset.allCases.compactMap { preset -> String? in
            preset == .disabled ? nil : "\(preset.keyCode)-\(preset.modifiers)"
        }
        #expect(Set(combos).count == combos.count, "сочетания не повторяются")
        // ⌃Space / ⌃⌥Space — переключение раскладки, ⌥⌘Space — поиск Finder.
        let reserved: Set<String> = [
            "\(kVK_Space)-\(controlKey)",
            "\(kVK_Space)-\(controlKey | optionKey)",
            "\(kVK_Space)-\(optionKey | cmdKey)",
        ]
        #expect(reserved.isDisjoint(with: combos))
        #expect(HotKeyPreset.disabled.title == "Выключена")
    }

    @Test func settingsDefaultsAndPersistence() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        #expect(settings.hotKey == .optionSpace)
        #expect(settings.openOnHover)
        #expect(settings.clipboardLimit == 100)

        settings.hotKey = .controlOptionN
        settings.openOnHover = false
        settings.clipboardLimit = 300

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.hotKey == .controlOptionN)
        #expect(!reloaded.openOnHover)
        #expect(reloaded.clipboardLimit == 300)
    }

    @Test func launchAtLoginStatusExplained() {
        #expect(LaunchAtLogin.State(status: .enabled) == .enabled)
        #expect(LaunchAtLogin.State(status: .notRegistered) == .disabled)
        #expect(LaunchAtLogin.State(status: .requiresApproval) == .needsApproval)
        #expect(LaunchAtLogin.State(status: .notFound) == .unavailable)
        #expect(LaunchAtLogin.State.needsApproval.hint?.contains("Объекты входа") == true)
        #expect(LaunchAtLogin.State.enabled.hint == nil)
        #expect(LaunchAtLogin.State.enabled.isOn)
        #expect(LaunchAtLogin.State.needsApproval.isOn, "запрошено — переключатель включён, ждём разрешения")
        #expect(!LaunchAtLogin.State.disabled.isOn)
    }

    /// Панель открывается там, где её оставили, — и после перезапуска.
    @Test func lastTabIsRemembered() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(PanelTab.stored(in: defaults) == .clipboard, "первый запуск — «Буфер»")
        PanelTab.translator.store(in: defaults)
        #expect(PanelTab.stored(in: defaults) == .translator)
        defaults.set("мусор", forKey: "panel.selectedTab")
        #expect(PanelTab.stored(in: defaults) == .clipboard)
    }

    @Test func clipboardLimitIsOneOfTheOffered() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(7, forKey: "clipboard.limit")
        #expect(AppSettings(defaults: defaults).clipboardLimit == 100, "мусор в настройках — значение по умолчанию")
        #expect(AppSettings.clipboardLimits == [50, 100, 300, 1000])
    }
}
