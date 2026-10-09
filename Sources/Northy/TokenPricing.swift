import Foundation

/// Примерная стоимость по ценам Claude API (первая сторона, $ за 1M токенов).
/// Цены раз в сутки берутся из общедоступной таблицы LiteLLM; встроенная таблица —
/// запасная (нет сети, первый запуск, модели нет в загруженных). Нет цены записи в кеш — ×1,25 от ввода
/// на 5 минут и ×2 на час; нет цены чтения кеша — ×0,1.
nonisolated enum TokenPricing {

    struct Rates: Equatable, Sendable, Codable {
        let input: Double
        let output: Double
        let cacheRead: Double
        let cacheWrite5m: Double
        let cacheWrite1h: Double

        init(input: Double, output: Double, cacheRead: Double? = nil, cacheWrite5m: Double? = nil, cacheWrite1h: Double? = nil) {
            self.input = input
            self.output = output
            self.cacheRead = cacheRead ?? input / 10
            self.cacheWrite5m = cacheWrite5m ?? input * 1.25
            self.cacheWrite1h = cacheWrite1h ?? input * 2
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

    private static let builtIn: [String: Rates] = [
        "claude-fable-5-1": Rates(input: 10, output: 50, cacheRead: 0.25),
        "claude-mythos-5-1": Rates(input: 10, output: 50, cacheRead: 0.25),
        "claude-fable-5": Rates(input: 10, output: 50),
        "claude-mythos-5": Rates(input: 10, output: 50),
        "claude-opus-5-5": Rates(input: 4, output: 20, cacheRead: 0.20),
        "claude-opus-5": Rates(input: 5, output: 25),
        "claude-opus-4-8": Rates(input: 5, output: 25),
        "claude-opus-4-7": Rates(input: 5, output: 25),
        "claude-opus-4-6": Rates(input: 5, output: 25),
        "claude-opus-4-5": Rates(input: 5, output: 25),
        "claude-opus-4": Rates(input: 15, output: 75),
        "claude-sonnet-5-5": Rates(input: 2, output: 10, cacheRead: 0.1),
        "claude-sonnet-5": Rates(input: 2, output: 10),
        "claude-sonnet-4": Rates(input: 3, output: 15),
        "claude-3-7-sonnet": Rates(input: 3, output: 15),
        "claude-haiku-5-5": Rates(input: 0.1, output: 0.5, cacheRead: 0.01),
        "claude-haiku-4-5": Rates(input: 1, output: 5),
        "claude-3-5-haiku": Rates(input: 0.8, output: 4),
    ]

    /// id может нести дату («…-20251001») или версию Vertex («…@20250929»). Из подходящих ключей обеих
    /// таблиц берётся самый длинный («opus-5-5», а не «opus-5»); при одинаковом ключе — загруженная цена.
    static func rates(for model: String, loaded: [String: Rates] = [:]) -> Rates? {
        let id = model.lowercased().split(separator: "@").first.map(String.init) ?? model.lowercased()
        return builtIn.merging(loaded) { _, fresh in fresh }
            .filter { id == $0.key || id.hasPrefix($0.key + "-") }
            .max { $0.key.count < $1.key.count }?.value
    }

    /// nil — модель неизвестна, стоимость не оценивается.
    static func cost(model: String, usage: Usage, loaded: [String: Rates] = [:]) -> Double? {
        rates(for: model, loaded: loaded).map { cost(usage, rates: $0) }
    }

    static func cost(_ usage: Usage, rates: Rates) -> Double {
        let cacheCreate1h = min(usage.cacheCreate1h, usage.cacheCreate)
        let cacheCreate5m = usage.cacheCreate - cacheCreate1h
        let perToken = Double(usage.input) * rates.input
            + Double(usage.output) * rates.output
            + Double(cacheCreate5m) * rates.cacheWrite5m
            + Double(cacheCreate1h) * rates.cacheWrite1h
            + Double(usage.cacheRead) * rates.cacheRead
        return perToken / 1_000_000
    }

    // MARK: таблица LiteLLM

    /// Единственный адрес, откуда берутся цены; у Anthropic машиночитаемого прайса нет.
    static let feedURL = URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!
    private static let feedByteLimit = 20_000_000

    /// Только записи первой стороны («anthropic», ключ «claude-…»); цена в таблице — за один токен.
    /// Данные чужие: запись без годных цен ввода и вывода пропускается, негодное необязательное поле — как отсутствующее.
    static func parseFeed(_ data: Data) -> [String: Rates] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var result: [String: Rates] = [:]
        for (key, value) in root {
            guard key.hasPrefix("claude-"), key.count <= 100,
                  let entry = value as? [String: Any],
                  entry["litellm_provider"] as? String == "anthropic"
            else { continue }
            func perMillion(_ field: String) -> Double? {
                guard let number = entry[field] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
                let price = number.doubleValue * 1_000_000
                return price.isFinite && price >= 0 ? price : nil
            }
            guard let input = perMillion("input_cost_per_token"), let output = perMillion("output_cost_per_token") else { continue }
            result[key.lowercased()] = Rates(
                input: input,
                output: output,
                cacheRead: perMillion("cache_read_input_token_cost"),
                cacheWrite5m: perMillion("cache_creation_input_token_cost"),
                cacheWrite1h: perMillion("cache_creation_input_token_cost_above_1hr")
            )
        }
        return result
    }

    /// Переадресация — только по HTTPS на тот же хост.
    private final class SameHostRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest
        ) async -> URLRequest? {
            request.url?.scheme == "https" && request.url?.host == feedURL.host ? request : nil
        }
    }

    private static let feedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 90
        return URLSession(configuration: configuration, delegate: SameHostRedirects(), delegateQueue: nil)
    }()

    /// nil — сеть недоступна, ответ слишком большой или в нём нет ни одной цены Claude.
    static func download() async -> [String: Rates]? {
        guard let (bytes, response) = try? await feedSession.bytes(from: feedURL),
              (response as? HTTPURLResponse)?.statusCode == 200,
              response.expectedContentLength <= Int64(feedByteLimit)
        else { return nil }
        var data = Data()
        do {
            // Читаем потоком, чтобы оборвать загрузку на лимите, а не после неё.
            for try await byte in bytes {
                data.append(byte)
                if data.count > feedByteLimit { return nil }
            }
        } catch {
            return nil
        }
        let rates = parseFeed(data)
        return rates.isEmpty ? nil : rates
    }

    // MARK: сохранённые цены

    /// На диске — только извлечённые цены Claude и время загрузки, не вся таблица.
    struct Saved: Equatable, Codable {
        let fetchedAt: Date
        let rates: [String: Rates]
    }

    @MainActor static var savedURL: URL { AppData.directory.appendingPathComponent("claude-prices.json") }

    static func readSaved(from url: URL) -> Saved? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Saved.self, from: data)
    }

    static func write(_ saved: Saved, to url: URL) {
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
