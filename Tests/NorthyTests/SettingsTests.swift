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
        defer { discardDefaults(defaults, suite: suite) }

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

    @Test func recordingAudioDefaultsAndPersistence() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { discardDefaults(defaults, suite: suite) }

        let settings = AppSettings(defaults: defaults)
        #expect(settings.recordingAudio == RecordingAudio(systemSound: true, microphone: .none), "первый запуск")

        settings.recordingAudio = RecordingAudio(systemSound: false, microphone: .systemDefault)
        #expect(AppSettings(defaults: defaults).recordingAudio == RecordingAudio(systemSound: false, microphone: .systemDefault))

        // Устройство может называться как угодно — хоть «default».
        settings.recordingAudio.microphone = .device("default")
        #expect(AppSettings(defaults: defaults).recordingAudio.microphone == .device("default"))

        settings.recordingAudio.microphone = .none
        #expect(AppSettings(defaults: defaults).recordingAudio.microphone == RecordingAudio.Microphone.none)
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
        defer { discardDefaults(defaults, suite: suite) }
        #expect(PanelTab.stored(in: defaults) == .clipboard, "первый запуск — «Буфер»")
        PanelTab.translator.store(in: defaults)
        #expect(PanelTab.stored(in: defaults) == .translator)
        defaults.set("мусор", forKey: "panel.selectedTab")
        #expect(PanelTab.stored(in: defaults) == .clipboard)
    }

    // MARK: вкладки

    @Test func tabsCanBeDisabledButClipboardStays() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { discardDefaults(defaults, suite: suite) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.enabledTabs == [.clipboard], "по умолчанию — только буфер")

        settings.enabledTabs = [.translator]
        #expect(settings.enabledTabs == [.clipboard, .translator], "буфер нельзя выключить")
        #expect(AppSettings(defaults: defaults).enabledTabs == [.clipboard, .translator], "переживает перезапуск")

        defaults.set(["files", "мусор"], forKey: "panel.enabledTabs")
        #expect(AppSettings(defaults: defaults).enabledTabs == [.clipboard, .files])
    }

    @Test func visibleTabsKeepOrderAndFallBackToClipboard() {
        let enabled: Set<PanelTab> = [.limits, .clipboard, .translator]
        #expect(PanelTab.visible(enabled: enabled) == [.clipboard, .translator, .limits])
        #expect(PanelTab.resolve(.translator, enabled: enabled) == .translator)
        #expect(PanelTab.resolve(.files, enabled: enabled) == .clipboard, "выключенная вкладка — на «Буфер»")
    }

    @Test func pinLimitDefaultsToFiveAndPersists() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { discardDefaults(defaults, suite: suite) }
        #expect(AppSettings(defaults: defaults).pinLimit == 5)
        AppSettings(defaults: defaults).pinLimit = 10
        #expect(AppSettings(defaults: defaults).pinLimit == 10)
        defaults.set(7, forKey: "clipboard.pinLimit")
        #expect(AppSettings(defaults: defaults).pinLimit == 5, "мусор — значение по умолчанию")
        #expect(AppSettings.pinLimits == [3, 5, 10, 20])
    }

    @Test func clipboardLimitIsOneOfTheOffered() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { discardDefaults(defaults, suite: suite) }
        defaults.set(7, forKey: "clipboard.limit")
        #expect(AppSettings(defaults: defaults).clipboardLimit == 100, "мусор в настройках — значение по умолчанию")
        #expect(AppSettings.clipboardLimits == [50, 100, 300, 1000])
    }
}

/// removePersistentDomain очищает значения, но файл набора остаётся в
/// ~/Library/Preferences — за прогоны их копились сотни. Удаляем и его.
func discardDefaults(_ defaults: UserDefaults, suite: String) {
    defaults.removePersistentDomain(forName: suite)
    let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Preferences/\(suite).plist")
    try? FileManager.default.removeItem(at: file)
}
