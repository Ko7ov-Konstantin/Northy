import Foundation
import Observation

/// Настройки приложения в UserDefaults. Меняются из окна настроек, читаются
/// контроллером панели и сторами.
@MainActor
@Observable
final class AppSettings {
    static let clipboardLimits = [50, 100, 300, 1000]
    static let pinLimits = [3, 5, 10, 20]

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

    /// Сколько записей буфера можно закрепить.
    var pinLimit: Int {
        didSet { defaults.set(pinLimit, forKey: Keys.pinLimit) }
    }

    /// Какие вкладки показывать; «Буфер» включён всегда.
    var enabledTabs: Set<PanelTab> {
        didSet {
            if !enabledTabs.contains(.clipboard) { enabledTabs.insert(.clipboard) }
            let saved = enabledTabs.union([.clipboard])
            defaults.set(PanelTab.allCases.filter(saved.contains).map(\.rawValue), forKey: Keys.enabledTabs)
        }
    }

    /// Видимые блоки вкладки «Лимиты» в порядке показа; скрытые лежат в лотке режима правки.
    var limitsBlocks: [LimitsBlock] {
        didSet { defaults.set(limitsBlocks.map(\.rawValue), forKey: Keys.limitsBlocks) }
    }

    /// Вкладка меню статус-бара: чьи лимиты показывать.
    var menuProvider: LimitsProvider {
        didSet { defaults.set(menuProvider.rawValue, forKey: Keys.menuProvider) }
    }

    /// Звук в записи экрана: звук системы и микрофон.
    var recordingAudio: RecordingAudio {
        didSet {
            defaults.set(recordingAudio.systemSound, forKey: Keys.recordingSystemSound)
            defaults.set(recordingAudio.microphone.stored, forKey: Keys.recordingMicrophone)
        }
    }

    /// Python-скрипт плитки «Скрипт» в «Инструментах»; путь приходит только из системного выбора файла.
    var scriptPath: String? {
        didSet { defaults.set(scriptPath, forKey: Keys.scriptPath) }
    }

    /// Модель и уровень рассуждений чата «Задать вопрос».
    var chatModel: ChatModel {
        didSet { defaults.set(chatModel.rawValue, forKey: Keys.chatModel) }
    }

    var chatEffort: ChatEffort {
        didSet { defaults.set(chatEffort.rawValue, forKey: Keys.chatEffort) }
    }

    /// Почему сочетание не назначилось (занято и т. п.); nil — всё в порядке. Не сохраняется.
    var hotKeyProblem: String?

    private enum Keys {
        static let hotKey = "hotkey.preset"
        static let openOnHover = "panel.openOnHover"
        static let clipboardLimit = "clipboard.limit"
        static let enabledTabs = "panel.enabledTabs"
        static let toolsTabOffered = "panel.toolsTabOffered"
        static let pinLimit = "clipboard.pinLimit"
        static let limitsBlocks = "limits.blocks"
        static let menuProvider = "limits.menuProvider"
        static let recordingSystemSound = "recording.systemSound"
        static let recordingMicrophone = "recording.microphone"
        static let scriptPath = "tools.scriptPath"
        static let chatModel = "chat.model"
        static let chatEffort = "chat.effort"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hotKey = defaults.string(forKey: Keys.hotKey).flatMap(HotKeyPreset.init(rawValue:)) ?? .optionSpace
        openOnHover = defaults.object(forKey: Keys.openOnHover) as? Bool ?? true
        let limit = defaults.integer(forKey: Keys.clipboardLimit)
        clipboardLimit = Self.clipboardLimits.contains(limit) ? limit : 100
        let pins = defaults.integer(forKey: Keys.pinLimit)
        pinLimit = Self.pinLimits.contains(pins) ? pins : 5
        if let stored = defaults.stringArray(forKey: Keys.enabledTabs) {
            var tabs = Set(stored.compactMap(PanelTab.init(rawValue:))).union([.clipboard])
            // «Инструменты» появились позже: у настроенного списка включаются один раз;
            // выключит пользователь — не вернутся.
            if !defaults.bool(forKey: Keys.toolsTabOffered) {
                tabs.insert(.tools)
                defaults.set(PanelTab.allCases.filter(tabs.contains).map(\.rawValue), forKey: Keys.enabledTabs)
            }
            enabledTabs = tabs
        } else {
            // По умолчанию — только «Буфер»; остальное включается в настройках.
            enabledTabs = [.clipboard]
        }
        defaults.set(true, forKey: Keys.toolsTabOffered)
        limitsBlocks = defaults.stringArray(forKey: Keys.limitsBlocks).map(LimitsBlock.sanitized) ?? LimitsBlock.allCases
        menuProvider = defaults.string(forKey: Keys.menuProvider).flatMap(LimitsProvider.init(rawValue:)) ?? .claude
        recordingAudio = RecordingAudio(
            systemSound: defaults.object(forKey: Keys.recordingSystemSound) as? Bool ?? true,
            microphone: RecordingAudio.Microphone(stored: defaults.string(forKey: Keys.recordingMicrophone))
        )
        scriptPath = defaults.string(forKey: Keys.scriptPath)
        chatModel = defaults.string(forKey: Keys.chatModel).flatMap(ChatModel.init(rawValue:)) ?? .opus
        chatEffort = defaults.string(forKey: Keys.chatEffort).flatMap(ChatEffort.init(rawValue:)) ?? .medium
    }
}
