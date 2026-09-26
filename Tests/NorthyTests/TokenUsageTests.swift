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
            TokenUsageScanner.Row(key: UUID().uuidString, timestamp: ISO8601DateFormatter().date(from: time)!, model: model, tokens: tokens, cost: Double(tokens) / 100)
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
            calendar: calendar
        )
        #expect(stats.today == 150)
        #expect(stats.currentSession == 100)
        #expect(stats.currentWeek == 1150)
        #expect(stats.lastTenDays == 1157)
        #expect(stats.daily.count == 10)
        #expect(stats.daily.last?.tokens == 150)
        #expect(stats.daily.first?.tokens == 7)
        #expect(stats.topModel == "claude-fable-5-1")
        #expect(abs(stats.todayCost - 1.5) < 0.0001)
        #expect(abs((stats.currentWeekCost ?? 0) - 11.5) < 0.0001)
        #expect(abs(stats.lastTenDaysCost - 11.57) < 0.0001)
        #expect(abs((stats.daily.last?.cost ?? 0) - 1.5) < 0.0001)
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

    @Test func parsedRowCarriesCostAndOneHourCache() {
        let json = #"{"type":"assistant","timestamp":"2026-09-26T10:00:00Z","requestId":"r","message":{"id":"m","model":"claude-haiku-4-5","usage":{"input_tokens":1000000,"output_tokens":0,"cache_creation_input_tokens":2000000,"cache_creation":{"ephemeral_1h_input_tokens":1000000},"cache_read_input_tokens":0}}}"#
        let row = TokenUsageScanner.parse(lines: [json]).first
        // Haiku: ввод $1 + 1M×$1,25 (5 мин) + 1M×$2 (1 ч).
        #expect(abs((row?.cost ?? 0) - 4.25) < 0.0001)
        #expect(row?.tokens == 3_000_000)
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
