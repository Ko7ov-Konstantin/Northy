import Testing
@testable import Northy

@MainActor
/// Циклы переключения и перестановка языков переводчика.
struct TranslationLanguageTests {

    @Test func sourceCycleCoversAllCases() {
        var current = SourceLanguage.auto
        var visited: [SourceLanguage] = []
        for _ in 0..<3 {
            current = current.next
            visited.append(current)
        }
        #expect(visited.contains(.auto))
        #expect(visited.contains(.ru))
        #expect(visited.contains(.en))
        #expect(current == .auto, "цикл замыкается")
    }

    @Test func targetCycleToggles() {
        #expect(TargetLanguage.ru.next == .en)
        #expect(TargetLanguage.en.next == .ru)
    }

    @Test func swappedWithExplicitSourceJustFlips() {
        let result = swapped(source: .ru, target: .en)
        #expect(result.source == .en)
        #expect(result.target == .ru)
    }

    @Test func swappedWithAutoPromotesTarget() {
        // Источник «Авто» сам не может стать целью — цель занимает его место,
        // новая цель — противоположный язык.
        let result = swapped(source: .auto, target: .en)
        #expect(result.source == .en)
        #expect(result.target == .ru)

        let reverse = swapped(source: .auto, target: .ru)
        #expect(reverse.source == .ru)
        #expect(reverse.target == .en)
    }
}
