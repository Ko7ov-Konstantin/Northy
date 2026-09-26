import Foundation

nonisolated enum Formatting {

    /// «1 файл», «3 файла», «5 файлов» — русские формы по последним цифрам.
    static func plural(_ count: Int, _ forms: (one: String, few: String, many: String)) -> String {
        let n = abs(count) % 100
        let last = n % 10
        let word: String
        if (11...14).contains(n) {
            word = forms.many
        } else if last == 1 {
            word = forms.one
        } else if (2...4).contains(last) {
            word = forms.few
        } else {
            word = forms.many
        }
        return "\(count) \(word)"
    }

    /// Доллары как у CodexBar: «$25.59», «$1,234.50».
    static func dollars(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").locale(Locale(identifier: "en_US")))
    }

    /// Компактное число токенов: «950», «12,4 тыс», «39,1 млн», «1,24 млрд».
    static func tokens(_ count: Int) -> String {
        let value = Double(count)
        let (scaled, unit): (Double, String) = switch value {
        case 1_000_000_000...: (value / 1_000_000_000, "млрд")
        case 1_000_000...: (value / 1_000_000, "млн")
        case 1_000...: (value / 1_000, "тыс")
        default: (value, "")
        }
        let digits = scaled < 10 ? 2 : (scaled < 100 ? 1 : 0)
        let number = scaled.formatted(
            .number.precision(.fractionLength(0...digits)).grouping(.never).locale(Locale(identifier: "ru_RU"))
        )
        return unit.isEmpty ? number : "\(number) \(unit)"
    }

    /// Сколько осталось до сброса лимита: «2 ч 14 мин», «3 дн 4 ч».
    static func countdown(to date: Date, now: Date = .now) -> String {
        let seconds = Int(date.timeIntervalSince(now))
        guard seconds >= 60 else { return "меньше минуты" }
        let days = seconds / 86_400
        let hours = seconds % 86_400 / 3600
        let minutes = seconds % 3600 / 60
        if days > 0 { return hours > 0 ? "\(days) дн \(hours) ч" : "\(days) дн" }
        if hours > 0 { return minutes > 0 ? "\(hours) ч \(minutes) мин" : "\(hours) ч" }
        return "\(minutes) мин"
    }

    /// Компактное «сколько прошло» для строк истории.
    static func relative(_ date: Date, now: Date = .now) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "только что"
        case ..<3600: return "\(Int(seconds / 60)) мин назад"
        case ..<86_400: return "\(Int(seconds / 3600)) ч назад"
        default: return "\(Int(seconds / 86_400)) дн назад"
        }
    }
}
