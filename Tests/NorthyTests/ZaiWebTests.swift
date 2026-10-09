import Foundation
import Testing
@testable import Northy

@MainActor
/// Лимиты GLM Coding Plan (Z.AI): запрос, разбор ответа и хранение ключа —
/// без сети и без настоящей Связки ключей.
struct ZaiWebTests {

    private let now = Date(timeIntervalSince1970: 1_785_800_000)

    private func quota(_ limits: String, extra: String = "") -> Data {
        Data(#"{"code":200,"msg":"success","success":true,"data":{\#(extra)"limits":[\#(limits)]}}"#.utf8)
    }

    private func ms(_ offset: TimeInterval) -> Int {
        Int((now.timeIntervalSince1970 + offset) * 1000)
    }

    // MARK: - Запрос

    @Test func requestSendsKeyOnlyToZai() {
        let request = ZaiWeb.request(apiKey: "secret-key")
        #expect(request.url?.absoluteString == "https://api.z.ai/api/monitor/usage/quota/limit")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-key")
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.timeoutInterval == 15)
    }

    // MARK: - Разбор

    @Test func parsesSessionWeekAndMcp() throws {
        let data = quota("""
        {"type":"TOKENS_LIMIT","unit":6,"number":1,"percentage":9,"nextResetTime":\(ms(3 * 86_400))},
        {"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":25,"nextResetTime":\(ms(2 * 3600))},
        {"type":"TIME_LIMIT","unit":5,"number":1,"usage":1000,"currentValue":224,"remaining":776,
         "percentage":22,"usageDetails":[{"modelCode":"search-prime","usage":210}]}
        """, extra: #""planName":" Pro ","#)
        let snapshot = try ZaiWeb.parseQuota(data, now: now)

        #expect(snapshot.plan == "Pro")
        #expect(snapshot.fetchedAt == now)
        #expect(snapshot.windows.map(\.kind) == [.session, .weekly, .custom("MCP · месяц")], "короткое окно первым, MCP последним")
        #expect(snapshot.windows.prefix(2).map(\.percent) == [25, 9])
        #expect(abs(snapshot.windows[2].percent - 22.4) < 0.001, "процент MCP — по счётчикам, а не по округлённому 22")
        #expect(snapshot.windows[0].resetsAt == now + 2 * 3600)
        #expect(snapshot.windows[1].resetsAt == now + 3 * 86_400)
        #expect(snapshot.windows[2].resetsAt == nil)
        #expect(snapshot.windows[2].duration == 30 * 86_400)
        #expect(snapshot.statusBarLines == ["5ч 75%", "7д 91%"])
    }

    @Test func creditLimitIsCodingPlanWindow() throws {
        let snapshot = try ZaiWeb.parseQuota(quota(#"{"type":"CREDIT_LIMIT","unit":3,"number":5,"percentage":40}"#), now: now)
        #expect(snapshot.windows.map(\.kind) == [.session])
        #expect(snapshot.windows[0].percent == 40)
    }

    /// Окно не на 5 часов и не на неделю получает свою подпись и длительность.
    @Test func unusualWindowKeepsItsDuration() throws {
        let snapshot = try ZaiWeb.parseQuota(
            quota(#"{"type":"TOKENS_LIMIT","unit":1,"number":30,"percentage":50,"nextResetTime":\#(ms(86_400))}"#), now: now
        )
        #expect(snapshot.windows.map(\.kind) == [.custom("Токены · 30 дн")])
        #expect(snapshot.windows[0].duration == 30 * 86_400)
        #expect(snapshot.windows[0].resetsAt == now + 86_400)
    }

    /// Счётчики точнее округлённого percentage; использовано — максимум из двух оценок.
    @Test func percentComesFromCounts() throws {
        let snapshot = try ZaiWeb.parseQuota(quota("""
        {"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":1,"usage":200,"remaining":150,"currentValue":20},
        {"type":"TOKENS_LIMIT","unit":6,"number":1,"percentage":1,"usage":400,"currentValue":100}
        """), now: now)
        #expect(snapshot.windows.map(\.percent) == [25, 25])
    }

    /// Сервер не назвал длину окна понятно — темп «в резерве / в дефиците» не выдумывается.
    @Test func unknownWindowLengthHasNoPace() throws {
        let snapshot = try ZaiWeb.parseQuota(
            quota(#"{"type":"TOKENS_LIMIT","unit":99,"number":1,"percentage":50,"nextResetTime":\#(ms(86_400))}"#), now: now
        )
        #expect(snapshot.windows.map(\.kind) == [.custom("Токены")])
        #expect(snapshot.windows[0].resetsAt == now + 86_400)
        #expect(UsagePace.make(for: snapshot.windows[0], now: now) == nil)
    }

    @Test func implausibleFiveHourResetIsDropped() throws {
        let snapshot = try ZaiWeb.parseQuota(
            quota(#"{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":25,"nextResetTime":\#(ms(10 * 3600))}"#), now: now
        )
        #expect(snapshot.windows[0].resetsAt == nil)
        #expect(snapshot.windows[0].percent == 25)
    }

    @Test func unknownAndBrokenEntriesAreSkipped() throws {
        let snapshot = try ZaiWeb.parseQuota(quota("""
        {"type":"FUTURE_POINTS_POOL","pointsRemaining":800},
        {"type":"TOKENS_LIMIT","unit":3,"number":5},
        {"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":140},
        "мусор"
        """), now: now)
        #expect(snapshot.windows.map(\.kind) == [.session])
        #expect(snapshot.windows[0].percent == 100)
    }

    @Test func emptyOrForeignResponsesAreErrors() {
        #expect(throws: ZaiWeb.FetchError.noLimits) { try ZaiWeb.parseQuota(quota(""), now: now) }
        #expect(throws: ZaiWeb.FetchError.noLimits) {
            try ZaiWeb.parseQuota(quota(#"{"type":"FUTURE_LIMIT","unit":3,"number":5,"percentage":40}"#), now: now)
        }
        #expect(throws: ZaiWeb.FetchError.invalidResponse) { try ZaiWeb.parseQuota(Data("<html>".utf8), now: now) }
        #expect(throws: ZaiWeb.FetchError.invalidResponse) {
            try ZaiWeb.parseQuota(Data(#"{"code":200,"success":true,"data":{"pointsPool":{}}}"#.utf8), now: now)
        }
    }

    /// Z.AI отвечает на неверный ключ HTTP 200 с кодом ошибки внутри; текст сервера в интерфейс не идёт.
    @Test func envelopeErrors() {
        let wrongKey = Data(#"{"code":401,"msg":"token expired or incorrect","success":false}"#.utf8)
        let noHeader = Data(#"{"code":1001,"msg":"Authentication parameter not received in Header","success":false}"#.utf8)
        let other = Data(#"{"code":500,"msg":"<script>","success":false}"#.utf8)
        #expect(throws: ZaiWeb.FetchError.unauthorized) { try ZaiWeb.parseQuota(wrongKey, now: now) }
        #expect(throws: ZaiWeb.FetchError.unauthorized) { try ZaiWeb.parseQuota(noHeader, now: now) }
        #expect(throws: ZaiWeb.FetchError.server(500)) { try ZaiWeb.parseQuota(other, now: now) }
        // Настоящий ответ Z.AI ключу без подписки: «у текущего пользователя нет coding plan».
        let noPlan = Data(#"{"code":500,"msg":"当前用户不存在coding plan","success":false}"#.utf8)
        #expect(throws: ZaiWeb.FetchError.noLimits) { try ZaiWeb.parseQuota(noPlan, now: now) }
        #expect(ZaiWeb.FetchError.server(500).errorDescription?.contains("script") == false)
    }

    @Test func httpStatusErrors() {
        #expect(ZaiWeb.error(forStatus: 401) == .unauthorized)
        #expect(ZaiWeb.error(forStatus: 403) == .unauthorized)
        #expect(ZaiWeb.error(forStatus: 429) == .rateLimited)
        #expect(ZaiWeb.error(forStatus: 502) == .server(502))
    }

    // MARK: - Детали квоты

    @Test func detailsShowCountsAndMcpTools() throws {
        let snapshot = try ZaiWeb.parseQuota(quota("""
        {"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":25,"usage":40000000,"remaining":30000000},
        {"type":"TOKENS_LIMIT","unit":6,"number":1,"percentage":9,"usage":400000000,"currentValue":36000000},
        {"type":"TIME_LIMIT","unit":5,"number":1,"usage":1000,"currentValue":224,"remaining":776,"percentage":22,
         "usageDetails":[{"modelCode":"search-prime","usage":210},{"modelCode":"  ","usage":1},{"modelCode":"zread","usage":"x"}]}
        """), now: now)
        #expect(snapshot.usesCredits == false)
        #expect(snapshot.details == [
            UsageDetail(label: "Квота токенов", value: "9% использовано", note: "лимит 400 млн"),
            UsageDetail(label: "Квота сеанса", value: "25% использовано", note: "лимит 40 млн · осталось 30 млн"),
            UsageDetail(label: "Квота MCP", value: "22,4% использовано", note: "лимит 1000 · осталось 776"),
            UsageDetail(label: "search-prime", value: "210", note: nil),
        ])
    }

    @Test func creditPlanIsMarked() throws {
        let snapshot = try ZaiWeb.parseQuota(
            quota(#"{"type":"CREDIT_LIMIT","unit":3,"number":5,"percentage":40,"usage":500,"remaining":300}"#), now: now
        )
        #expect(snapshot.usesCredits)
        #expect(snapshot.details == [UsageDetail(label: "Квота кредитов", value: "40% использовано", note: "лимит 500 · осталось 300")])
    }

    // MARK: - Пиковое время

    private func utc(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: text)!
    }

    /// Пик — будни 06:00–10:00 UTC (14:00–18:00 по Пекину); выходные — вне пика.
    @Test func peakHours() {
        // 2026-10-05 — понедельник.
        #expect(ZaiPeak(now: utc("2026-10-05T05:59:00Z")) == ZaiPeak(isPeak: false, changesAt: utc("2026-10-05T06:00:00Z")))
        #expect(ZaiPeak(now: utc("2026-10-05T06:00:00Z")) == ZaiPeak(isPeak: true, changesAt: utc("2026-10-05T10:00:00Z")))
        #expect(ZaiPeak(now: utc("2026-10-05T09:59:59Z")) == ZaiPeak(isPeak: true, changesAt: utc("2026-10-05T10:00:00Z")))
        #expect(ZaiPeak(now: utc("2026-10-05T10:00:00Z")) == ZaiPeak(isPeak: false, changesAt: utc("2026-10-06T06:00:00Z")))
        // Пятница после пика и суббота в «пиковые» часы — ждём понедельника.
        #expect(ZaiPeak(now: utc("2026-10-09T12:00:00Z")) == ZaiPeak(isPeak: false, changesAt: utc("2026-10-12T06:00:00Z")))
        #expect(ZaiPeak(now: utc("2026-10-10T07:00:00Z")) == ZaiPeak(isPeak: false, changesAt: utc("2026-10-12T06:00:00Z")))
    }

    @Test func peakRowText() {
        let peak = ZaiPeak(now: utc("2026-10-05T08:30:00Z"))
        let now = utc("2026-10-05T08:30:00Z")
        #expect(peak.detail(usesCredits: true, now: now) == UsageDetail(label: "Тариф списания", value: "Пик · 1×", note: "вне пика через 1 ч 30 мин"))
        let quiet = ZaiPeak(now: utc("2026-10-05T04:00:00Z"))
        #expect(quiet.detail(usesCredits: true, now: utc("2026-10-05T04:00:00Z")) == UsageDetail(label: "Тариф списания", value: "Вне пика · 0,5×", note: "пик через 2 ч"))
        #expect(quiet.detail(usesCredits: false, now: utc("2026-10-05T04:00:00Z")).value == "Вне пика")
    }

    // MARK: - Токены по моделям

    @Test func modelUsageRequestCoversWholeDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let request = ZaiWeb.modelUsageRequest(apiKey: "secret-key", daysBack: 1, now: utc("2026-10-05T08:30:10Z"), calendar: calendar)
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.host == "api.z.ai")
        #expect(components.path == "/api/monitor/usage/model-usage")
        #expect(components.queryItems == [
            URLQueryItem(name: "startTime", value: "2026-10-04 00:00:00"),
            URLQueryItem(name: "endTime", value: "2026-10-05 08:59:59"),
        ])
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-key")
    }

    @Test func modelUsageBecomesSeries() throws {
        let data = Data(#"""
        {"code":200,"success":true,"data":{"x_time":["10:00","11:00","12:00"],"modelDataList":[
          {"modelName":"glm-4.7","tokensUsage":[100,0,50]},
          {"modelName":"glm-5","tokensUsage":[1000,0,null]},
          {"modelName":"idle","tokensUsage":[0,0,0]}
        ]}}
        """#.utf8)
        let series = try #require(ZaiWeb.parseModelUsage(data, title: "Токены по часам"))
        #expect(series.title == "Токены по часам")
        #expect(series.points == [.init(label: "10:00", value: 1100), .init(label: "12:00", value: 50)], "пустые часы не рисуются")
        #expect(series.totals == [.init(name: "glm-5", tokens: 1000), .init(name: "glm-4.7", tokens: 150)])
    }

    /// Необязательная аналитика: непригодный ответ — просто нет графика.
    @Test func brokenModelUsageIsIgnored() {
        func series(_ json: String) -> UsageSeries? { ZaiWeb.parseModelUsage(Data(json.utf8), title: "т") }
        #expect(series(#"{"code":401,"success":false}"#) == nil)
        #expect(series(#"{"code":200,"success":true,"data":{"x_time":[],"modelDataList":[]}}"#) == nil)
        #expect(series(#"{"code":200,"success":true,"data":{"x_time":["  "],"modelDataList":[{"modelName":"m","tokensUsage":[1]}]}}"#) == nil)
        let long = String(repeating: "x", count: 121)
        #expect(series(#"{"code":200,"success":true,"data":{"x_time":["h"],"modelDataList":[{"modelName":"\#(long)","tokensUsage":[1]}]}}"#) == nil)
        let many = (0..<121).map { #""h\#($0)""# }.joined(separator: ",")
        let ones = Array(repeating: "1", count: 121).joined(separator: ",")
        #expect(series(#"{"code":200,"success":true,"data":{"x_time":[\#(many)],"modelDataList":[{"modelName":"m","tokensUsage":[\#(ones)]}]}}"#) == nil)
        #expect(series(#"{"code":200,"success":true,"data":{"x_time":["h"],"modelDataList":[{"modelName":"m","tokensUsage":[1e308]}]}}"#) == nil)
    }

    // MARK: - Окна других источников не меняются

    @Test func claudeWindowsKeepDefaultDurations() {
        #expect(UsageWindow(kind: .session, percent: 1, resetsAt: nil).duration == 5 * 3600)
        #expect(UsageWindow(kind: .weekly, percent: 1, resetsAt: nil).duration == 7 * 86_400)
        #expect(UsageWindow(kind: .model("Fable"), percent: 1, resetsAt: nil).duration == 7 * 86_400)
    }

    /// Темп месячного окна считается от 30 дней, а не от недели.
    @Test func paceUsesWindowDuration() throws {
        let window = UsageWindow(kind: .custom("MCP · месяц"), percent: 50, resetsAt: now + 15 * 86_400, duration: 30 * 86_400)
        let pace = try #require(UsagePace.make(for: window, now: now))
        #expect(abs(pace.deltaPercent) < 0.001)
        #expect(window.title == "MCP · месяц")
    }

    // MARK: - Ключ

    private final class MemoryBackend: SecretBackend, @unchecked Sendable {
        var value: String?
        var reads = 0
        var readError: Error?
        func exists() -> Bool { value != nil }
        func read() throws -> String? {
            reads += 1
            if let readError { throw readError }
            return value
        }
        func write(_ value: String?) throws { self.value = value }
    }

    @Test func keyIsTrimmedStoredAndRemoved() async throws {
        let backend = MemoryBackend()
        let keys = ZaiKeyStore(backend: backend)
        #expect(!keys.hasKey)
        #expect(try await keys.key() == nil)
        #expect(backend.reads == 0, "без ключа Связка ключей не читается")

        try keys.save("  abc.def-123\n")
        #expect(keys.hasKey)
        #expect(backend.value == "abc.def-123")
        #expect(try await keys.key() == "abc.def-123")

        try keys.save("")
        #expect(!keys.hasKey)
        #expect(backend.value == nil)
    }

    @Test func keyWithSpacesOrControlCharactersIsRejected() {
        let keys = ZaiKeyStore(backend: MemoryBackend())
        #expect(throws: ZaiKeyStore.KeyError.invalid) { try keys.save("abc def") }
        #expect(throws: ZaiKeyStore.KeyError.invalid) { try keys.save("abc\r\nX-Injected: 1") }
        #expect(throws: ZaiKeyStore.KeyError.invalid) { try keys.save(String(repeating: "a", count: 600)) }
        #expect(!keys.hasKey)
    }

    @Test func storedKeyIsReadOnceThenCached() async throws {
        let backend = MemoryBackend()
        backend.value = "stored"
        let keys = ZaiKeyStore(backend: backend)
        #expect(keys.hasKey)
        #expect(try await keys.key() == "stored")
        #expect(try await keys.key() == "stored")
        #expect(backend.reads == 1)
    }

    @Test func sourceWithoutKeyDoesNotCallNetwork() async {
        let source = ZaiLimitsSource(keys: ZaiKeyStore(backend: MemoryBackend()))
        await #expect(throws: ZaiWeb.FetchError.noKey) { try await source.fetch() }
    }

    @Test func deniedKeychainIsReportedWithoutKey() async {
        let backend = MemoryBackend()
        backend.value = "stored"
        backend.readError = KeychainSecret.Failure(status: errSecUserCanceled)
        let source = ZaiLimitsSource(keys: ZaiKeyStore(backend: backend))
        await #expect(throws: ZaiWeb.FetchError.keychainDenied) { try await source.fetch() }
    }

    /// Ключ заменили, пока шёл запрос со старым: его ответ не должен появиться после сброса.
    @Test func resetDiscardsRequestInFlight() async {
        @MainActor final class Gate: LimitsSource {
            var continuation: CheckedContinuation<UsageSnapshot, Error>?
            var calls = 0
            func fetch() async throws -> UsageSnapshot {
                calls += 1
                return try await withCheckedThrowingContinuation { continuation = $0 }
            }
        }
        let gate = Gate()
        let store = LimitsStore(source: gate, minInterval: 0)
        let old = Task { await store.refresh(force: true) }
        while gate.continuation == nil { await Task.yield() }
        let stale = gate.continuation
        gate.continuation = nil

        store.reset()
        let fresh = Task { await store.refresh(force: true) }
        while gate.continuation == nil { await Task.yield() }
        #expect(gate.calls == 2, "новый запрос уходит, не дожидаясь старого")

        stale?.resume(returning: UsageSnapshot(windows: [UsageWindow(kind: .session, percent: 99, resetsAt: nil)], fetchedAt: .now))
        await old.value
        #expect(store.snapshot == nil)
        #expect(store.isLoading)

        gate.continuation?.resume(returning: UsageSnapshot(windows: [UsageWindow(kind: .session, percent: 10, resetsAt: nil)], fetchedAt: .now))
        await fresh.value
        #expect(store.snapshot?.windows.first?.percent == 10)
        #expect(!store.isLoading)
    }

    @Test func storeResetDropsSnapshotAndError() async {
        struct Failing: LimitsSource {
            func fetch() async throws -> UsageSnapshot { throw ZaiWeb.FetchError.unauthorized }
        }
        let store = LimitsStore(source: Failing(), minInterval: 0)
        await store.refresh()
        #expect(store.errorMessage != nil)
        store.reset()
        #expect(store.errorMessage == nil)
        #expect(store.snapshot == nil)
    }
}
