import Foundation

/// Примерная стоимость по ценам Claude API (первая сторона, $ за 1M токенов).
/// Запись в кеш — ×1,25 от ввода на 5 минут и ×2 на час; чтение кеша — ×0,1,
/// кроме Fable 5.1 / Mythos 5.1 ($0,25) и Opus 5.5 ($0,20).
nonisolated enum TokenPricing {

    struct Rates: Equatable, Sendable {
        let input: Double
        let output: Double
        let cacheRead: Double

        var cacheWrite5m: Double { input * 1.25 }
        var cacheWrite1h: Double { input * 2 }

        init(input: Double, output: Double, cacheRead: Double? = nil) {
            self.input = input
            self.output = output
            self.cacheRead = cacheRead ?? input / 10
        }
    }

    struct Usage: Equatable, Sendable {
        var input = 0
        var output = 0
        /// Все записи в кеш; из них `cacheCreate1h` — с часовым сроком.
        var cacheCreate = 0
        var cacheCreate1h = 0
        var cacheRead = 0

        var total: Int { input + output + cacheCreate + cacheRead }
    }

    /// Порядок важен: более конкретный префикс идёт раньше («opus-5-5» до «opus-5»).
    private static let table: [(prefix: String, rates: Rates)] = [
        ("claude-fable-5-1", Rates(input: 10, output: 50, cacheRead: 0.25)),
        ("claude-mythos-5-1", Rates(input: 10, output: 50, cacheRead: 0.25)),
        ("claude-fable-5", Rates(input: 10, output: 50)),
        ("claude-mythos-5", Rates(input: 10, output: 50)),
        ("claude-opus-5-5", Rates(input: 4, output: 20, cacheRead: 0.20)),
        ("claude-opus-5", Rates(input: 5, output: 25)),
        ("claude-opus-4-8", Rates(input: 5, output: 25)),
        ("claude-opus-4-7", Rates(input: 5, output: 25)),
        ("claude-opus-4-6", Rates(input: 5, output: 25)),
        ("claude-opus-4-5", Rates(input: 5, output: 25)),
        ("claude-opus-4", Rates(input: 15, output: 75)),
        ("claude-sonnet-5", Rates(input: 2, output: 10)),
        ("claude-sonnet-4", Rates(input: 3, output: 15)),
        ("claude-3-7-sonnet", Rates(input: 3, output: 15)),
        ("claude-haiku-4-5", Rates(input: 1, output: 5)),
        ("claude-3-5-haiku", Rates(input: 0.8, output: 4)),
    ]

    /// id может нести дату («…-20251001») или версию Vertex («…@20250929») — префикс это не ломает.
    static func rates(for model: String) -> Rates? {
        let id = model.lowercased().split(separator: "@").first.map(String.init) ?? model.lowercased()
        return table.first { id == $0.prefix || id.hasPrefix($0.prefix + "-") }?.rates
    }

    /// nil — модель неизвестна, стоимость не оценивается.
    static func cost(model: String, usage: Usage) -> Double? {
        guard let rates = rates(for: model) else { return nil }
        let cacheCreate1h = min(usage.cacheCreate1h, usage.cacheCreate)
        let cacheCreate5m = usage.cacheCreate - cacheCreate1h
        let perToken = Double(usage.input) * rates.input
            + Double(usage.output) * rates.output
            + Double(cacheCreate5m) * rates.cacheWrite5m
            + Double(cacheCreate1h) * rates.cacheWrite1h
            + Double(usage.cacheRead) * rates.cacheRead
        return perToken / 1_000_000
    }
}
