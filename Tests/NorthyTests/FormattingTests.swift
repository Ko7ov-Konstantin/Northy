import Foundation
import Testing
@testable import Northy

@MainActor
struct FormattingTests {

    @Test func russianPluralForms() {
        let forms = ("файл", "файла", "файлов")
        #expect(Formatting.plural(1, forms) == "1 файл")
        #expect(Formatting.plural(3, forms) == "3 файла")
        #expect(Formatting.plural(5, forms) == "5 файлов")
        #expect(Formatting.plural(11, forms) == "11 файлов")
        #expect(Formatting.plural(12, forms) == "12 файлов")
        #expect(Formatting.plural(21, forms) == "21 файл")
        #expect(Formatting.plural(104, forms) == "104 файла")
        #expect(Formatting.plural(0, forms) == "0 файлов")
    }

    @Test func relativeTimeBuckets() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(Formatting.relative(now.addingTimeInterval(-20), now: now) == "только что")
        #expect(Formatting.relative(now.addingTimeInterval(-5 * 60), now: now) == "5 мин назад")
        #expect(Formatting.relative(now.addingTimeInterval(-3 * 3600), now: now) == "3 ч назад")
        #expect(Formatting.relative(now.addingTimeInterval(-2 * 86_400), now: now) == "2 дн назад")
        // Будущее (часы переведены назад) не даёт отрицательных чисел.
        #expect(Formatting.relative(now.addingTimeInterval(120), now: now) == "только что")
    }
}
