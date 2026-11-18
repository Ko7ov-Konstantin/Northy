import Foundation
import Testing
@testable import Northy

@MainActor
/// Лимиты Gemini по входу Google из Antigravity: файл токена, обновление токена,
/// запросы и разбор ответов — без сети и без настоящего файла.
struct GeminiWebTests {

    private let now = Date(timeIntervalSince1970: 1_785_800_000)

    private func idToken(_ claims: String) -> String {
        let payload = Data(claims.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(payload).signature"
    }

    private func tokenFile(expiry: String) -> Data {
        let id = idToken(#"{"aud":"123-abc.apps.googleusercontent.com","email":"user@example.com"}"#)
        return Data("""
        {"token":{"access_token":"access-1","token_type":"Bearer","refresh_token":"refresh-1","expiry":"\(expiry)"},
         "auth_method":"consumer","id_token":"\(id)"}
        """.utf8)
    }

    /// Образец ответа retrieveUserQuotaSummary из тестов CodexBar.
    private let summary = Data("""
    {"response":{"description":"Within each group, models share a weekly limit and a 5-hour limit.","groups":[
      {"displayName":"Gemini Models","description":"Models within this group: Gemini Flash, Gemini Pro","buckets":[
        {"bucketId":"gemini-weekly","displayName":"Weekly Limit","remaining":{"remainingFraction":0.82},"resetTime":"2026-06-19T08:45:39Z"},
        {"bucketId":"gemini-5h","displayName":"Five Hour Limit","remaining":{"remainingFraction":0.91},"resetTime":"2026-06-15T11:39:34Z"}]},
      {"displayName":"Claude and GPT models","description":"Models within this group: Claude Opus, Claude Sonnet, GPT-OSS","buckets":[
        {"bucketId":"3p-weekly","displayName":"Weekly Limit","remaining":{"remainingFraction":0.64},"resetTime":"2026-06-20T00:39:54Z"},
        {"bucketId":"3p-5h","displayName":"Five Hour Limit","remaining":{"remainingFraction":0.73},"resetTime":"2026-06-15T12:52:10Z"}]}
    ]}}
    """.utf8)

    private func date(_ text: String) -> Date? {
        ISO8601DateFormatter().date(from: text)
    }

    // MARK: - Файл токена

    @Test func readsAntigravityTokenFile() throws {
        let credentials = try GeminiWeb.parseCredentials(tokenFile(expiry: "2026-10-13T19:42:24.825372+04:00"))
        #expect(credentials.accessToken == "access-1")
        #expect(credentials.refreshToken == "refresh-1")
        #expect(credentials.expiresAt == date("2026-10-13T15:42:24Z"))
        #expect(credentials.clientID == "123-abc.apps.googleusercontent.com")
        #expect(credentials.email == "user@example.com")
    }

    @Test func brokenTokenFileMeansNoLogin() {
        #expect(throws: GeminiWeb.FetchError.notLoggedIn) { try GeminiWeb.parseCredentials(Data("мусор".utf8)) }
        #expect(throws: GeminiWeb.FetchError.notLoggedIn) { try GeminiWeb.parseCredentials(Data(#"{"token":{}}"#.utf8)) }
    }

    @Test func tokenIsRefreshedMinuteBeforeExpiry() {
        #expect(GeminiWeb.needsRefresh(expiresAt: now + 3600, now: now) == false)
        #expect(GeminiWeb.needsRefresh(expiresAt: now + 30, now: now))
        #expect(GeminiWeb.needsRefresh(expiresAt: now - 3600, now: now))
        #expect(GeminiWeb.needsRefresh(expiresAt: nil, now: now), "срок неизвестен — токену не доверяем")
    }

    // MARK: - Обновление токена

    @Test func refreshRequestGoesOnlyToGoogleTokenEndpoint() throws {
        let request = GeminiWeb.refreshRequest(clientID: "123-abc.apps.googleusercontent.com", clientSecret: "GOCSPX-s/1", refreshToken: "1//refresh")
        #expect(request.url?.absoluteString == "https://oauth2.googleapis.com/token")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(request.httpShouldHandleCookies == false)
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(body == "client_id=123-abc.apps.googleusercontent.com&client_secret=GOCSPX-s%2F1&refresh_token=1%2F%2Frefresh&grant_type=refresh_token")
    }

    @Test func refreshAnswerGivesTokenOrReason() {
        let ok = Data(#"{"access_token":"fresh","expires_in":3599,"token_type":"Bearer"}"#.utf8)
        #expect(GeminiWeb.parseRefresh(status: 200, data: ok, now: now) == .token("fresh", expiresAt: now + 3599))
        let wrongClient = Data(#"{"error":"invalid_client","error_description":"Unauthorized"}"#.utf8)
        #expect(GeminiWeb.parseRefresh(status: 401, data: wrongClient, now: now) == .wrongClient)
        let revoked = Data(#"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#.utf8)
        #expect(GeminiWeb.parseRefresh(status: 400, data: revoked, now: now) == .rejected)
        #expect(GeminiWeb.parseRefresh(status: 200, data: Data("{}".utf8), now: now) == .rejected, "200 без токена — не успех")
    }

    @Test func findsClientSecretsInBinary() {
        let first = "GOCSPX-" + String(repeating: "a", count: 28)
        let second = "GOCSPX-" + String(repeating: "B", count: 20) + "_-345678"
        var binary = Data([0x00, 0xFF, 0x10])
        binary.append(Data(first.utf8))
        binary.append(Data([0x00, 0x00]))
        binary.append(Data(second.utf8))
        binary.append(Data("xx".utf8))
        binary.append(Data(first.utf8))
        binary.append(Data("GOCSPX-short".utf8))
        #expect(GeminiWeb.clientSecrets(in: binary) == [first, second], "повтор и обрезанная строка отброшены")
        #expect(GeminiWeb.clientSecrets(in: Data("ничего похожего".utf8)).isEmpty)
    }

    // MARK: - Запросы

    @Test func apiRequestLooksLikeAntigravity() throws {
        let request = GeminiWeb.apiRequest("retrieveUserQuotaSummary", accessToken: "access-1", body: ["project": "p-1"])
        #expect(request.url?.absoluteString == "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-1")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let agent = try #require(request.value(forHTTPHeaderField: "User-Agent"))
        #expect(agent.hasPrefix("antigravity/hub/"))
        #expect(agent.contains(" darwin/"))
        #expect(request.httpShouldHandleCookies == false)
        let body = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: String]
        #expect(body == ["project": "p-1"])
    }

    @Test func statusCodesBecomeReadableErrors() {
        #expect(GeminiWeb.error(forStatus: 401) == .sessionExpired)
        #expect(GeminiWeb.error(forStatus: 403) == .forbidden)
        #expect(GeminiWeb.error(forStatus: 429) == .rateLimited)
        #expect(GeminiWeb.error(forStatus: 503) == .server(503))
    }

    @Test func codeAssistGivesProjectAndPlan() {
        let plain = Data(#"{"cloudaicompanionProject":"p-1","planInfo":{"planType":"Pro"},"currentTier":{"id":"free-tier"}}"#.utf8)
        #expect(GeminiWeb.parseCodeAssist(plain).project == "p-1")
        #expect(GeminiWeb.parseCodeAssist(plain).plan == "Pro")
        let object = Data(#"{"cloudaicompanionProject":{"id":"p-2"},"currentTier":{"id":"standard-tier","name":"Standard"}}"#.utf8)
        #expect(GeminiWeb.parseCodeAssist(object).project == "p-2")
        #expect(GeminiWeb.parseCodeAssist(object).plan == "Paid")
        let named = Data(#"{"currentTier":{"id":"g1-ultra","name":"Google AI Ultra"}}"#.utf8)
        #expect(GeminiWeb.parseCodeAssist(named).project == nil)
        #expect(GeminiWeb.parseCodeAssist(named).plan == "Google AI Ultra")
        #expect(GeminiWeb.parseCodeAssist(Data("[]".utf8)).plan == nil)
    }

    /// У подписчика Google AI базовый тариф остаётся free-tier, а подписка приходит в paidTier.
    @Test func paidTierWinsOverFreeTier() {
        let data = Data(#"{"currentTier":{"id":"free-tier","name":"Antigravity"},"paidTier":{"id":"g1-pro-tier","name":"Google AI Pro"}}"#.utf8)
        #expect(GeminiWeb.parseCodeAssist(data).plan == "Google AI Pro")
        let unnamed = Data(#"{"currentTier":{"id":"free-tier"},"paidTier":{"id":"g1-pro-tier"}}"#.utf8)
        #expect(GeminiWeb.parseCodeAssist(unnamed).plan == "Free", "без названия подписки — базовый тариф")
    }

    // MARK: - Сводка квоты

    @Test func parsesGeminiAndClaudeGptWindows() throws {
        let snapshot = try GeminiWeb.parseQuotaSummary(summary, now: now)
        #expect(snapshot.fetchedAt == now)
        #expect(snapshot.windows.map(\.kind) == [
            .session, .weekly, .custom("Claude/GPT · 5 часов"), .custom("Claude/GPT · неделя"),
        ], "пятичасовое окно перед недельным, Gemini перед Claude/GPT")
        #expect(snapshot.windows.map { $0.percent.rounded() } == [9, 18, 27, 36])
        #expect(snapshot.windows.map(\.resetsAt) == [
            date("2026-06-15T11:39:34Z"), date("2026-06-19T08:45:39Z"), date("2026-06-15T12:52:10Z"), date("2026-06-20T00:39:54Z"),
        ])
        let durations: [TimeInterval] = [18_000, 604_800, 18_000, 604_800]
        #expect(snapshot.windows.map(\.duration) == durations)
        #expect(snapshot.statusBarLines == ["5ч 91%", "7д 82%"])
        #expect(snapshot.details == [
            UsageDetail(label: "Gemini Models", value: "Gemini Flash, Gemini Pro"),
            UsageDetail(label: "Claude and GPT models", value: "Claude Opus, Claude Sonnet, GPT-OSS"),
        ])
    }

    @Test func readsOneofRemainingAndExplicitWindow() throws {
        let data = Data("""
        {"groups":[{"displayName":"Gemini Models","buckets":[
          {"bucketId":"a","displayName":"Limit","window":"weekly","remaining":{"case":"remainingFraction","value":0.5}},
          {"bucketId":"b","displayName":"Limit","window":"5h","remainingFraction":0.25}]}]}
        """.utf8)
        let snapshot = try GeminiWeb.parseQuotaSummary(data, now: now)
        #expect(snapshot.windows.map(\.kind) == [.session, .weekly])
        #expect(snapshot.windows.map(\.percent) == [75, 50])
        #expect(snapshot.windows.map(\.resetsAt) == [nil, nil])
    }

    /// Тариф Starter отдаёт только недельные лимиты — пятичасовое окно не выдумывается.
    @Test func weeklyOnlyPlanHasNoSessionWindow() throws {
        let data = Data("""
        {"response":{"groups":[
          {"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-weekly","displayName":"Weekly Limit","remaining":{"remainingFraction":1}}]},
          {"displayName":"Claude and GPT models","buckets":[{"bucketId":"3p-weekly","displayName":"Weekly Limit","remaining":{"remainingFraction":0.4}}]}]}}
        """.utf8)
        let snapshot = try GeminiWeb.parseQuotaSummary(data, now: now)
        #expect(snapshot.windows.map(\.kind) == [.weekly, .custom("Claude/GPT · неделя")])
        #expect(snapshot.windows.map(\.percent) == [0, 60])
        #expect(snapshot.headline?.kind == .weekly)
    }

    @Test func unknownCadenceKeepsBucketName() throws {
        let data = Data(#"{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-daily","displayName":"Daily Limit","remaining":{"remainingFraction":0.9}}]}]}"#.utf8)
        let window = try #require(try GeminiWeb.parseQuotaSummary(data, now: now).windows.first)
        #expect(window.kind == .custom("Gemini · Daily Limit"))
        #expect(window.duration == 0, "длина окна неизвестна — темп не считается")
    }

    @Test func bucketsWithoutKnownUsageAreSkipped() throws {
        let mixed = Data("""
        {"response":{"groups":[{"displayName":"Gemini Models","buckets":[
          {"bucketId":"gemini-weekly","displayName":"Weekly Limit","description":"Refreshes later."},
          {"bucketId":"gemini-5h","displayName":"Five Hour Limit","disabled":true,"remaining":{"remainingFraction":0.5}},
          {"bucketId":"gemini-extra","displayName":"Extra","remaining":{"remainingFraction":0.2}}]}]}}
        """.utf8)
        #expect(try GeminiWeb.parseQuotaSummary(mixed, now: now).windows.map(\.kind) == [.custom("Gemini · Extra")])

        let unknown = Data(#"{"response":{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-weekly","displayName":"Weekly Limit"}]}]}}"#.utf8)
        #expect(throws: GeminiWeb.FetchError.noLimits) { try GeminiWeb.parseQuotaSummary(unknown, now: now) }
        #expect(throws: GeminiWeb.FetchError.invalidResponse) { try GeminiWeb.parseQuotaSummary(Data("{}".utf8), now: now) }
        #expect(throws: GeminiWeb.FetchError.invalidResponse) { try GeminiWeb.parseQuotaSummary(Data("не json".utf8), now: now) }
    }

    // MARK: - Запасной ответ по моделям

    @Test func modelBucketsBecomeWindowsWithLowestRemaining() throws {
        let data = Data("""
        {"buckets":[
          {"modelId":"gemini-3-pro","remainingFraction":0.8,"resetTime":"2026-06-15T11:39:34Z"},
          {"modelId":"gemini-3-flash","remainingFraction":1},
          {"modelId":"gemini-3-pro","remainingFraction":0.3,"resetTime":"2026-06-16T11:39:34Z"},
          {"modelId":"  ","remainingFraction":0.1},
          {"modelId":"no-usage"}]}
        """.utf8)
        let snapshot = try GeminiWeb.parseQuotaBuckets(data, now: now)
        #expect(snapshot.windows.map(\.kind) == [.custom("gemini-3-flash"), .custom("gemini-3-pro")])
        #expect(snapshot.windows.map { $0.percent.rounded() } == [0, 70])
        #expect(snapshot.windows[1].resetsAt == date("2026-06-16T11:39:34Z"))
        #expect(throws: GeminiWeb.FetchError.noLimits) { try GeminiWeb.parseQuotaBuckets(Data(#"{"buckets":[]}"#.utf8), now: now) }
        #expect(throws: GeminiWeb.FetchError.invalidResponse) { try GeminiWeb.parseQuotaBuckets(Data("{}".utf8), now: now) }
    }

    // MARK: - Antigravity CLI (agy)

    @Test func findsCLIByOverrideOrStandardPaths() {
        let home = URL(fileURLWithPath: "/Users/tester")
        let override = GeminiWeb.findCLI(
            environment: ["ANTIGRAVITY_CLI_PATH": "/custom/agy"],
            home: home,
            isExecutable: { $0 == "/custom/agy" }
        )
        #expect(override?.path == "/custom/agy")

        let local = GeminiWeb.findCLI(
            environment: [:],
            home: home,
            isExecutable: { $0 == "/Users/tester/.local/bin/agy" }
        )
        #expect(local?.path == "/Users/tester/.local/bin/agy")

        let brew = GeminiWeb.findCLI(
            environment: [:],
            home: home,
            isExecutable: { $0 == "/opt/homebrew/bin/agy" }
        )
        #expect(brew?.path == "/opt/homebrew/bin/agy")

        #expect(GeminiWeb.findCLI(environment: [:], home: home, isExecutable: { _ in false }) == nil)
    }

    @Test func cliEnvironmentDisablesAutoUpdateAndStripsAPIKeys() {
        let env = GeminiWeb.cliEnvironment(
            from: ["PATH": "/usr/local/bin", "GEMINI_API_KEY": "secret", "GOOGLE_API_KEY": "secret2", "HOME": "/Users/tester"],
            binaryDirectory: URL(fileURLWithPath: "/Users/tester/.local/bin")
        )
        #expect(env["AGY_CLI_DISABLE_AUTO_UPDATE"] == "true")
        #expect(env["GEMINI_API_KEY"] == nil)
        #expect(env["GOOGLE_API_KEY"] == nil)
        #expect(env["HOME"] == "/Users/tester")
        #expect(env["PATH"] == "/Users/tester/.local/bin:/usr/local/bin:/usr/bin:/bin")
    }

    /// Актуальный вывод `agy -p "/usage" --output-format json`:
    /// общий пул Gemini Models, Claude/GPT и отдельная группа Gemini 4 Argon.
    @Test func parsesCLIUsageWithArgonSeparateFromPrimaryGemini() throws {
        let cliOutput = Data("""
        {"conversation_id":"","status":"SUCCESS","response":"...","command":{"name":"usage","data":{
          "groups":[
            {"name":"Gemini Models","description":"Models within this group: Gemini 4 Neon, Gemini 4 Hydrogen, Orchestrator (Neon), Gemini 3.8 Flash","buckets":[
              {"id":"gemini-weekly","name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":0.9862,"reset_time":"2026-11-25T22:30:20Z"},
              {"id":"gemini-5h","name":"Five Hour Limit Remaining","window":"5h","remaining_fraction":0.9517,"reset_time":"2026-11-19T03:30:20Z"}]},
            {"name":"Claude and GPT models","description":"Models within this group: Claude Opus 5.5, Claude Sonnet 5.5, GPT-OSS 120B","buckets":[
              {"id":"3p-weekly","name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":1,"reset_time":"2026-11-25T22:37:32Z"},
              {"id":"3p-5h","name":"Five Hour Limit Remaining","window":"5h","remaining_fraction":1,"reset_time":"2026-11-19T03:37:32Z"}]},
            {"name":"Gemini 4 Argon","description":"For paid Pro plans, Argon quota is separate. Higher Argon quota (included as part of the larger Gemini quota bucket) is available on Ultra plans.","buckets":[
              {"id":"gemini-argon-wtu-weekly","name":"Gemini 4 Argon Weekly Limit","window":"weekly","remaining_fraction":0.99,"reset_time":"2026-11-25T22:33:51Z"}]}
          ]
        }}}
        """.utf8)
        let snapshot = try GeminiWeb.parseCLIUsage(cliOutput, now: now)
        #expect(snapshot.windows.map(\.kind) == [
            .session, .weekly,
            .custom("Claude/GPT · 5 часов"), .custom("Claude/GPT · неделя"),
            .custom("Gemini 4 Argon · неделя"),
        ])
        #expect(snapshot.windows.map(\.remaining) == [95, 99, 100, 100, 99])
        #expect(snapshot.windows[4].duration == 7 * 86_400)
        #expect(snapshot.windows[4].resetsAt == date("2026-11-25T22:33:51Z"))
        #expect(snapshot.statusBarLines == ["5ч 95%", "7д 99%"])
        #expect(snapshot.details == [
            UsageDetail(label: "Gemini Models", value: "Gemini 4 Neon, Gemini 4 Hydrogen, Orchestrator (Neon), Gemini 3.8 Flash"),
            UsageDetail(label: "Claude and GPT models", value: "Claude Opus 5.5, Claude Sonnet 5.5, GPT-OSS 120B"),
        ], "описательная справка про тарифы у Argon не засоряет список моделей")
    }

    @Test func separateGeminiModelBeforePrimaryDoesNotStealWeekly() throws {
        let data = Data("""
        {"command":{"data":{"groups":[
          {"name":"Gemini 4 Argon","buckets":[
            {"id":"gemini-argon-wtu-weekly","name":"Gemini 4 Argon Weekly Limit","remaining_fraction":0.5}]},
          {"name":"Gemini Models","buckets":[
            {"id":"gemini-weekly","name":"Weekly Limit Remaining","remaining_fraction":0.8},
            {"id":"gemini-5h","name":"Five Hour Limit Remaining","remaining_fraction":0.9}]}
        ]}}}
        """.utf8)
        let snapshot = try GeminiWeb.parseCLIUsage(data, now: now)
        #expect(snapshot.windows.map(\.kind) == [.custom("Gemini 4 Argon · неделя"), .session, .weekly])
        #expect(snapshot.windows.map(\.remaining) == [50, 90, 80])
    }

    @Test func cliUsageIgnoresLogLinesBeforeJSONAndMapsErrors() throws {
        let noisy = Data("""
        WARNING: something
        {"status":"SUCCESS","command":{"data":{"groups":[{"name":"Gemini Models","buckets":[{"id":"gemini-5h","window":"5h","remaining_fraction":0.75}]}]}}}
        """.utf8)
        let snapshot = try GeminiWeb.parseCLIUsage(noisy, now: now)
        #expect(snapshot.windows.map(\.kind) == [.session])
        #expect(snapshot.windows.map(\.remaining) == [75])

        let authErr = Data(#"{"status":"ERROR","error":"Authentication required: please sign in"}"#.utf8)
        #expect(throws: GeminiWeb.FetchError.sessionExpired) { try GeminiWeb.parseCLIUsage(authErr, exitCode: 1, now: now) }

        let apiKeyErr = Data(#"{"status":"ERROR","response":"No account quota when using GEMINI_API_KEY"}"#.utf8)
        #expect(throws: GeminiWeb.FetchError.noLimits) { try GeminiWeb.parseCLIUsage(apiKeyErr, exitCode: 2, now: now) }

        #expect(throws: GeminiWeb.FetchError.rateLimited) { try GeminiWeb.parseCLIUsage(Data(), exitCode: 1, stderr: "HTTP 429 too many requests", now: now) }
        #expect(throws: GeminiWeb.FetchError.forbidden) { try GeminiWeb.parseCLIUsage(Data(), exitCode: 1, stderr: "403 permission denied", now: now) }
        #expect(throws: GeminiWeb.FetchError.invalidResponse) { try GeminiWeb.parseCLIUsage(Data("мусор".utf8), exitCode: 0, now: now) }
    }

    @Test func limitsSourceUsesCLIWhenInstalled() async throws {
        let payload = Data("""
        {"status":"SUCCESS","command":{"name":"usage","data":{"groups":[
          {"name":"Gemini Models","buckets":[
            {"id":"gemini-5h","window":"5h","remaining_fraction":0.9},
            {"id":"gemini-weekly","window":"weekly","remaining_fraction":0.8}]}
        ]}}}
        """.utf8)
        let source = GeminiLimitsSource(
            findCLI: { URL(fileURLWithPath: "/usr/local/bin/agy") },
            runCLI: { _ in (payload, Data(), 0) }
        )
        let snapshot = try await source.fetch()
        #expect(snapshot.statusBarLines == ["5ч 90%", "7д 80%"])
    }
}
