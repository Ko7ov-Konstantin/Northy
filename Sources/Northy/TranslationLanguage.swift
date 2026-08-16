import Foundation

enum SourceLanguage: String, CaseIterable, Identifiable {
    case auto = "Авто"
    case ru = "RU"
    case en = "EN"

    var id: String { rawValue }

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
