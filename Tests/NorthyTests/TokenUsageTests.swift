import Foundation
import Testing
@testable import Northy

@MainActor
/// Токены по локальным логам Claude Code (~/.claude/projects/**/*.jsonl) —
/// как сканер CodexBar, но без расчёта стоимости.
struct TokenUsageTests {

    private func tempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NorthyTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Цена $10 000 за 1M ввода: стоимость строки = токены / 100.
    private let centPrices = [
        "claude-opus-5-5": TokenPricing.Rates(input: 10_000, output: 0),
        "claude-fable-5-1": TokenPricing.Rates(input: 10_000, output: 0),
    ]

    private func line(
        type: String = "assistant",
        time: String,
        model: String = "claude-opus-5-5",
        messageID: String? = "m1",
        requestID: String? = "r1",
        input: Int = 10, output: Int = 20, cacheCreate: Int = 30, cacheRead: Int = 40
    ) -> String {
        let message = messageID.map { "\"id\":\"\($0)\"," } ?? ""
        let request = requestID.map { ",\"requestId\":\"\($0)\"" } ?? ""
        return """
        {"type":"\(type)","timestamp":"\(time)"\(request),"message":{\(message)"model":"\(model)","usage":{"input_tokens":\(input),"output_tokens":\(output),"cache_creation_input_tokens":\(cacheCreate),"cache_read_input_tokens":\(cacheRead)}}}
        """
    }

    @Test func parsesAssistantUsageLines() {
        let rows = TokenUsageScanner.parse(lines: [
            line(time: "2026-09-26T10:00:00.000Z"),
            line(type: "user", time: "2026-09-26T10:00:00.000Z", messageID: "u"),
            line(time: "2026-09-26T10:01:00Z", messageID: "m2", input: 0, output: 0, cacheCreate: 0, cacheRead: 0),
            line(time: "2026-09-26T10:02:00Z", model: "<synthetic>", messageID: "m3"),
            "не json",
        ])
        #expect(rows.count == 1)
        #expect(rows.first?.tokens == 100)
        #expect(rows.first?.model == "claude-opus-5-5")
        #expect(rows.first?.key == "m1|r1")
    }

    @Test func scanDedupsAcrossFilesAndSkipsOldFiles() throws {
        let root = tempDirectory()
        let project = root.appendingPathComponent("projects/-Users-me-app", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        // Возобновлённая сессия копирует историю — тот же ответ в двух файлах.
        let shared = line(time: "2026-09-26T10:00:00Z", messageID: "m1", requestID: "r1")
        try [shared, line(time: "2026-09-26T11:00:00Z", messageID: "m2", requestID: "r2")]
            .joined(separator: "\n").write(to: project.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)
        try [shared].joined(separator: "\n").write(to: project.appendingPathComponent("b.jsonl"), atomically: true, encoding: .utf8)
        let old = project.appendingPathComponent("old.jsonl")
        try line(time: "2026-01-01T00:00:00Z", messageID: "m9", requestID: "r9").write(to: old, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: old.path)

        let scanner = TokenUsageScanner(projectRoots: [root.appendingPathComponent("projects")])
        let since = ISO8601DateFormatter().date(from: "2026-09-20T00:00:00Z")!
        let rows = scanner.scan(since: since)
        #expect(rows.count == 2, "общий ответ посчитан один раз, старый файл не читается")
    }

    @Test func statsAggregateTodayWindowDaysAndTopModel() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = ISO8601DateFormatter().date(from: "2026-09-26T12:00:00Z")!
        func row(_ time: String, _ tokens: Int, _ model: String = "claude-opus-5-5") -> TokenUsageScanner.Row {
            TokenUsageScanner.Row(key: UUID().uuidString, timestamp: ISO8601DateFormatter().date(from: time)!, model: model, usage: .init(input: tokens))
        }
        let rows = [
            row("2026-09-26T11:30:00Z", 100),
            row("2026-09-26T06:00:00Z", 50),
            row("2026-09-25T10:00:00Z", 1000, "claude-fable-5-1"),
            row("2026-09-17T10:00:00Z", 7, "claude-fable-5-1"),
            row("2026-09-10T10:00:00Z", 999_999),
        ]
        let stats = TokenStats.make(
            rows: rows,
            now: now,
            sessionStart: ISO8601DateFormatter().date(from: "2026-09-26T08:00:00Z"),
            weekStart: ISO8601DateFormatter().date(from: "2026-09-20T00:00:00Z"),
            calendar: calendar,
            prices: centPrices
        )
        #expect(stats.today == 150)
        #expect(stats.currentSession == 100)
        #expect(stats.currentWeek == 1150)
        #expect(stats.daily.count == 26, "по дню на каждое число с 1 сентября")
        #expect(stats.daily.last?.tokens == 150)
        #expect(stats.daily.first?.tokens == 0)
        #expect(stats.daily.first { $0.tokens == 7 } != nil)
        #expect(stats.topModel == "claude-opus-5-5")
        #expect(abs(stats.todayCost - 1.5) < 0.0001)
        #expect(abs((stats.currentWeekCost ?? 0) - 11.5) < 0.0001)
        #expect(abs((stats.daily.last?.cost ?? 0) - 1.5) < 0.0001)
        #expect(stats.hasUsage)
    }

    /// «С 1 числа»: весь текущий месяц по сегодня, прошлый месяц не считается.
    @Test func statsCountMonthToDate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = { (raw: String) in ISO8601DateFormatter().date(from: raw)! }
        func row(_ time: String, _ tokens: Int) -> TokenUsageScanner.Row {
            TokenUsageScanner.Row(key: UUID().uuidString, timestamp: date(time), model: "claude-opus-5-5", usage: .init(input: tokens))
        }
        let rows = [
            row("2026-08-31T23:59:00Z", 5000),
            row("2026-09-01T00:00:00Z", 1),
            row("2026-09-10T10:00:00Z", 20),
            row("2026-09-26T11:00:00Z", 300),
        ]
        let now = date("2026-09-26T12:00:00Z")
        let stats = TokenStats.make(rows: rows, now: now, sessionStart: nil, weekStart: nil, calendar: calendar, prices: centPrices)
        #expect(stats.monthStart == date("2026-09-01T00:00:00Z"))
        #expect(stats.monthToDate == 321)
        #expect(abs(stats.monthToDateCost - 3.21) < 0.0001)
        #expect(stats.daily.first?.date == date("2026-09-01T00:00:00Z"))
        #expect(stats.daily.first?.tokens == 1)
        #expect(stats.daily.reduce(0) { $0 + $1.tokens } == 321, "график — те же дни, что итог")

        #expect(TokenStats.scanStart(now: now, calendar: calendar) == date("2026-09-01T00:00:00Z"), "в конце месяца читаем с 1 числа")
        #expect(TokenStats.scanStart(now: date("2026-09-03T12:00:00Z"), calendar: calendar) == date("2026-08-27T00:00:00Z"), "в начале месяца — неделя назад: окно лимита началось в прошлом месяце")
    }

    /// 1 число, ещё ничего не потрачено, но недельное окно с прошлого месяца идёт — блок стоимости показываем.
    @Test func weeklyWindowAloneCountsAsUsage() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = { (raw: String) in ISO8601DateFormatter().date(from: raw)! }
        let rows = [TokenUsageScanner.Row(key: "a", timestamp: date("2026-09-29T10:00:00Z"), model: "claude-opus-5-5", usage: .init(input: 40))]
        let stats = TokenStats.make(rows: rows, now: date("2026-10-01T08:00:00Z"), sessionStart: nil, weekStart: date("2026-09-28T00:00:00Z"), calendar: calendar)
        #expect(stats.monthToDate == 0)
        #expect(stats.daily.count == 1)
        #expect(stats.currentWeek == 40)
        #expect(stats.hasUsage)
        #expect(!TokenStats.make(rows: [], now: date("2026-10-01T08:00:00Z"), sessionStart: nil, weekStart: nil, calendar: calendar).hasUsage)
    }

    // MARK: цены API

    @Test func costUsesModelRatesAndCacheMultipliers() throws {
        // Opus 5.5: ввод $4, вывод $20, запись кеша 5 мин ×1,25, 1 ч ×2, чтение $0,20 за 1M.
        let usage = TokenPricing.Usage(input: 1_000_000, output: 1_000_000, cacheCreate: 2_000_000, cacheCreate1h: 1_000_000, cacheRead: 10_000_000)
        let cost = try #require(TokenPricing.cost(model: "claude-opus-5-5", usage: usage))
        #expect(abs(cost - (4 + 20 + 5 + 8 + 2)) < 0.0001)
    }

    @Test func pricingCoversCurrentAndOlderModels() {
        func rates(_ model: String) -> [Double]? {
            TokenPricing.rates(for: model).map { [$0.input, $0.output, $0.cacheRead] }
        }
        #expect(rates("claude-fable-5-1") == [10, 50, 0.25])
        #expect(rates("claude-fable-5") == [10, 50, 1])
        #expect(rates("claude-opus-5") == [5, 25, 0.5])
        #expect(rates("claude-opus-4-8") == [5, 25, 0.5])
        #expect(rates("claude-opus-4-5-20251101") == [5, 25, 0.5], "дата в конце id не мешает")
        #expect(rates("claude-opus-4-1") == [15, 75, 1.5])
        #expect(rates("claude-sonnet-5") == [2, 10, 0.2])
        #expect(rates("claude-sonnet-4-6") == [3, 15, 0.3])
        #expect(rates("claude-haiku-4-5-20251001") == [1, 5, 0.1])
        #expect(rates("claude-sonnet-4-5@20250929") == [3, 15, 0.3], "формат Vertex")
        #expect(rates("gpt-5") == nil)
    }

    @Test func parsedRowCarriesCostAndOneHourCache() throws {
        let json = #"{"type":"assistant","timestamp":"2026-09-26T10:00:00Z","requestId":"r","message":{"id":"m","model":"claude-haiku-4-5","usage":{"input_tokens":1000000,"output_tokens":0,"cache_creation_input_tokens":2000000,"cache_creation":{"ephemeral_1h_input_tokens":1000000},"cache_read_input_tokens":0}}}"#
        let row = try #require(TokenUsageScanner.parse(lines: [json]).first)
        // Haiku: ввод $1 + 1M×$1,25 (5 мин) + 1M×$2 (1 ч).
        #expect(abs((TokenPricing.cost(model: row.model, usage: row.usage) ?? 0) - 4.25) < 0.0001)
        #expect(row.tokens == 3_000_000)
    }

    // MARK: цены из таблицы LiteLLM

    private let feed = """
    {
      "sample_spec": {"input_cost_per_token": 0, "litellm_provider": "one of https://docs.litellm.ai/docs/providers"},
      "claude-haiku-5-5": {"litellm_provider": "anthropic", "input_cost_per_token": 1e-07, "output_cost_per_token": 5e-07, "cache_read_input_token_cost": 1e-08, "cache_creation_input_token_cost": 1.25e-07, "cache_creation_input_token_cost_above_1hr": 2e-07},
      "claude-opus-5": {"litellm_provider": "anthropic", "input_cost_per_token": 5e-06, "output_cost_per_token": 2.5e-05},
      "claude-opus-5-5": {"litellm_provider": "anthropic", "input_cost_per_token": 4e-06, "output_cost_per_token": 2e-05, "cache_read_input_token_cost": 2e-07, "cache_creation_input_token_cost": 5e-06},
      "claude-sonnet-4-5": {"litellm_provider": "anthropic", "input_cost_per_token": 3.3e-06, "output_cost_per_token": 1.5e-05},
      "claude-new-9": {"litellm_provider": "bedrock", "input_cost_per_token": 1e-06, "output_cost_per_token": 1e-06},
      "gpt-9": {"litellm_provider": "anthropic", "input_cost_per_token": 1e-06, "output_cost_per_token": 1e-06},
      "claude-fable-5-1": {"litellm_provider": "anthropic", "input_cost_per_token": -1, "output_cost_per_token": 5e-05},
      "claude-mythos-5-1": {"litellm_provider": "anthropic", "input_cost_per_token": "дорого", "output_cost_per_token": 5e-05},
      "claude-haiku-4-5": {"litellm_provider": "anthropic", "input_cost_per_token": 1e-06, "output_cost_per_token": 5e-06, "cache_read_input_token_cost": -3, "cache_creation_input_token_cost": true},
      "claude-junk": "строка вместо объекта",
      "claude-list": [1, 2]
    }
    """

    @Test func feedGivesRatesForModelMissingFromCode() throws {
        let loaded = TokenPricing.parseFeed(Data(feed.utf8))
        let rates = try #require(TokenPricing.rates(for: "claude-haiku-5-5-20260301", loaded: loaded))
        let got = [rates.input, rates.output, rates.cacheRead, rates.cacheWrite5m, rates.cacheWrite1h]
        for (value, expected) in zip(got, [0.1, 0.5, 0.01, 0.125, 0.2]) { #expect(abs(value - expected) < 1e-9) }
    }

    @Test func feedLongestKeyWinsAndVertexIdMatches() {
        let loaded = TokenPricing.parseFeed(Data(feed.utf8))
        #expect(TokenPricing.rates(for: "claude-opus-5-5-20260101", loaded: loaded)?.input == 4)
        #expect(TokenPricing.rates(for: "claude-opus-5-20250801", loaded: loaded)?.input == 5)
        #expect(abs((TokenPricing.rates(for: "Claude-Sonnet-4-5@20250929", loaded: loaded)?.input ?? 0) - 3.3) < 1e-9, "формат Vertex, цена из загруженных")
        #expect(TokenPricing.rates(for: "claude-sonnet-4-6", loaded: loaded)?.input == 3, "нет в загруженных — встроенная таблица")
    }

    /// Самый длинный ключ ищется по обеим таблицам вместе; при равном ключе важнее загруженная цена.
    @Test func longestKeyWinsAcrossLoadedAndBuiltIn() {
        let short = ["claude-opus-5": TokenPricing.Rates(input: 99, output: 999)]
        #expect(TokenPricing.rates(for: "claude-opus-5-5-20260101", loaded: short) == TokenPricing.Rates(input: 4, output: 20, cacheRead: 0.2))
        #expect(TokenPricing.rates(for: "claude-opus-5-20250801", loaded: short)?.input == 99)
        let same = ["claude-opus-5-5": TokenPricing.Rates(input: 7, output: 70)]
        #expect(TokenPricing.rates(for: "claude-opus-5-5-20260101", loaded: same) == TokenPricing.Rates(input: 7, output: 70))
    }

    @Test func feedSkipsForeignProvidersAndGarbage() {
        let loaded = TokenPricing.parseFeed(Data(feed.utf8))
        #expect(Set(loaded.keys) == ["claude-haiku-5-5", "claude-opus-5", "claude-opus-5-5", "claude-sonnet-4-5", "claude-haiku-4-5"])
        #expect(TokenPricing.rates(for: "claude-new-9", loaded: loaded) == nil, "bedrock не берём")
        // Отрицательная и нечисловая цена ввода — запись пропущена, работает встроенная таблица.
        #expect(TokenPricing.rates(for: "claude-fable-5-1", loaded: loaded) == TokenPricing.Rates(input: 10, output: 50, cacheRead: 0.25))
        #expect(TokenPricing.rates(for: "claude-mythos-5-1", loaded: loaded)?.cacheRead == 0.25)
        // Негодные необязательные поля заменяются множителями от ввода.
        #expect(loaded["claude-haiku-4-5"] == TokenPricing.Rates(input: 1, output: 5))

        for broken in ["не json", "[1,2]", "", "{\"claude-x\": {"] {
            let empty = TokenPricing.parseFeed(Data(broken.utf8))
            #expect(empty.isEmpty)
            #expect(TokenPricing.rates(for: "claude-opus-5-5", loaded: empty)?.cacheRead == 0.2)
        }
    }

    @Test func feedWithoutHourlyCacheWriteDoublesInput() {
        let loaded = TokenPricing.parseFeed(Data(feed.utf8))
        #expect(loaded["claude-opus-5-5"]?.cacheWrite5m == 5)
        #expect(loaded["claude-opus-5-5"]?.cacheWrite1h == 8)
        #expect(loaded["claude-opus-5"]?.cacheRead == 0.5)
    }

    @Test func builtInTableKnowsNewModels() {
        #expect(TokenPricing.rates(for: "claude-haiku-5-5") == TokenPricing.Rates(input: 0.1, output: 0.5, cacheRead: 0.01))
        #expect(TokenPricing.rates(for: "claude-sonnet-5-5-20260901") == TokenPricing.Rates(input: 2, output: 10, cacheRead: 0.1))
    }

    /// Строка разобрана, когда цены модели ещё не было: стоимость появляется, как только пришла цена.
    @Test func rowParsedBeforePriceIsCostedOnceRatesArrive() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let rows = TokenUsageScanner.parse(lines: [line(time: "2026-09-26T10:00:00Z", model: "claude-nova-7-20260901", input: 1_000_000, output: 0, cacheCreate: 0, cacheRead: 0)])
        let now = ISO8601DateFormatter().date(from: "2026-09-26T12:00:00Z")!
        let before = TokenStats.make(rows: rows, now: now, sessionStart: nil, weekStart: nil, calendar: calendar)
        #expect(before.today == 1_000_000)
        #expect(before.todayCost == 0)

        let loaded = TokenPricing.parseFeed(Data(#"{"claude-nova-7": {"litellm_provider": "anthropic", "input_cost_per_token": 3e-06, "output_cost_per_token": 1e-05}}"#.utf8))
        let after = TokenStats.make(rows: rows, now: now, sessionStart: nil, weekStart: nil, calendar: calendar, prices: loaded)
        #expect(abs(after.todayCost - 3) < 1e-9)
        #expect(abs(after.monthToDateCost - 3) < 1e-9)
        #expect(abs((ClaudeSessions.make(rows: rows.map { var row = $0; row.sessionID = "s"; return row }, now: now, calendar: calendar, prices: loaded).first?.todayCost ?? 0) - 3) < 1e-9)
    }

    @Test func savedPricesRoundTripThroughFile() throws {
        let file = tempDirectory().appendingPathComponent("prices.json")
        #expect(TokenPricing.readSaved(from: file) == nil)
        let saved = TokenPricing.Saved(fetchedAt: Date(timeIntervalSince1970: 1_800_000_000), rates: TokenPricing.parseFeed(Data(feed.utf8)))
        TokenPricing.write(saved, to: file)
        #expect(TokenPricing.readSaved(from: file) == saved)
        try Data("мусор".utf8).write(to: file)
        #expect(TokenPricing.readSaved(from: file) == nil)
    }

    @Test func dollarFormatting() {
        #expect(Formatting.dollars(25.594) == "$25.59")
        #expect(Formatting.dollars(308.4) == "$308.40")
        #expect(Formatting.dollars(1234.5) == "$1,234.50")
        #expect(Formatting.dollars(0.004) == "$0.00")
    }

    @Test func compactTokenFormatting() {
        #expect(Formatting.tokens(950) == "950")
        #expect(Formatting.tokens(12_400) == "12,4 тыс")
        #expect(Formatting.tokens(2_000_000) == "2 млн")
        #expect(Formatting.tokens(39_100_000) == "39,1 млн")
        #expect(Formatting.tokens(917_000_000) == "917 млн")
        #expect(Formatting.tokens(1_240_000_000) == "1,24 млрд")
    }
}
