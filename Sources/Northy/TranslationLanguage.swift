import Foundation

enum SourceLanguage: String, CaseIterable, Identifiable {
    case auto = "Авто"
    case ru = "RU"
    case en = "EN"

    var id: String { rawValue }

    /// Циклическое переключение кнопкой: Авто → RU → EN → Авто.
    var next: SourceLanguage {
        switch self {
        case .auto: .ru
        case .ru: .en
        case .en: .auto
        }
    }

    var locale: Locale.Language? {
        switch self {
        case .auto: nil
        case .ru: Locale.Language(identifier: "ru")
        case .en: Locale.Language(identifier: "en")
        }
    }
}

enum TargetLanguage: String, CaseIterable, Identifiable {
    case ru = "RU"
    case en = "EN"

    var id: String { rawValue }

    var next: TargetLanguage {
        self == .ru ? .en : .ru
    }

    var locale: Locale.Language {
        switch self {
        case .ru: Locale.Language(identifier: "ru")
        case .en: Locale.Language(identifier: "en")
        }
    }

    var asSource: SourceLanguage {
        self == .ru ? .ru : .en
    }
}

/// Перестановка языков местами. «Авто» не может стать целью: текущая цель
/// занимает место источника, новой целью становится противоположный язык.
/// Явная пара просто меняется местами.
func swapped(source: SourceLanguage, target: TargetLanguage) -> (source: SourceLanguage, target: TargetLanguage) {
    let newSource = target.asSource
    let newTarget: TargetLanguage = source.locale == nil
        ? target.next
        : (source == .ru ? .ru : .en)
    return (newSource, newTarget)
}
