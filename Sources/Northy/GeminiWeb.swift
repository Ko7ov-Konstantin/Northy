import Foundation

/// Лимиты Gemini через установленный Antigravity CLI (`agy -p "/usage" --output-format json`).
/// Если CLI не найден, запасной путь читает прежний файл входа Google в ~/.gemini
/// и ходит на cloudcode-pa.googleapis.com (loadCodeAssist / retrieveUserQuotaSummary).
nonisolated enum GeminiWeb {

    static let tokenFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".gemini/jetski-standalone-oauth-token")
    static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    static let clientMetadata = ["ideType": "ANTIGRAVITY", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI"]
    static let cliCandidates = [".local/bin/agy", "/opt/homebrew/bin/agy", "/usr/local/bin/agy"]
    static let cliArguments = ["-p", "/usage", "--output-format", "json", "--print-timeout", "20s"]

    /// Без актуальной подписи клиента Antigravity Google отдаёт заглушку «100% по всем окнам».
    private static let userAgent: String = {
        let version = installedAppVersion() ?? "2.33.0"
        #if arch(arm64)
        return "antigravity/hub/\(version) darwin/arm64"
        #else
        return "antigravity/hub/\(version) darwin/amd64"
        #endif
    }()

    static var hasCLI: Bool { findCLI() != nil }
    static var hasTokenFile: Bool { FileManager.default.fileExists(atPath: tokenFile.path) }
    static var hasLogin: Bool { hasCLI || hasTokenFile }

    /// У GUI-приложения урезанный PATH, поэтому бинарник `agy` ищется по списку.
    static func findCLI(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> URL? {
        if let override = text(environment["ANTIGRAVITY_CLI_PATH"]), isExecutable(override) {
            return URL(fileURLWithPath: override)
        }
        return cliCandidates
            .map { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : home.appendingPathComponent($0) }
            .first { isExecutable($0.path) }
    }

    /// С ключами API `/usage` завершается ошибкой (у ключа нет квоты аккаунта),
    /// а без `AGY_CLI_DISABLE_AUTO_UPDATE=true` фоновый опрос запускает автообновление CLI.
    static func cliEnvironment(from base: [String: String], binaryDirectory: URL) -> [String: String] {
        var environment = base
        environment["AGY_CLI_DISABLE_AUTO_UPDATE"] = "true"
        environment["GEMINI_API_KEY"] = nil
        environment["GOOGLE_API_KEY"] = nil
        var path = [binaryDirectory.path] + (base["PATH"] ?? "").split(separator: ":").map(String.init)
        for system in ["/usr/bin", "/bin"] where !path.contains(system) { path.append(system) }
        environment["PATH"] = path.joined(separator: ":")
        return environment
    }

    private static func installedAppVersion() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let plists = [
            URL(fileURLWithPath: "/Applications/Antigravity.app/Contents/Info.plist"),
            home.appendingPathComponent("Applications/Antigravity.app/Contents/Info.plist"),
        ]
        for url in plists {
            guard let info = NSDictionary(contentsOf: url),
                  let version = text(info["CFBundleShortVersionString"])
            else { continue }
            return version
        }
        return nil
    }

    enum FetchError: LocalizedError, Equatable {
        case notLoggedIn
        case sessionExpired
        case clientNotFound
        case forbidden
        case rateLimited
        case server(Int)
        case invalidResponse
        case noLimits

        var errorDescription: String? {
            switch self {
            case .notLoggedIn:
                "Вход Google не найден — войдите в Antigravity"
            case .sessionExpired:
                "Google не принял вход Antigravity — войдите в Antigravity заново"
            case .clientNotFound:
                "Не удалось обновить вход Google: программа Antigravity не найдена или изменилась"
            case .forbidden:
                "Google не даёт этому аккаунту читать квоту"
            case .rateLimited:
                "Google просит подождать — попробуйте через пару минут"
            case .server(let code):
                "Google ответил ошибкой \(code)"
            case .invalidResponse:
                "Не удалось разобрать ответ Google"
            case .noLimits:
                "Google не отдал лимиты для этого аккаунта"
            }
        }
    }

    // MARK: - Файл токена

    struct Credentials: Equatable, Sendable {
        let accessToken: String?
        let refreshToken: String?
        let expiresAt: Date?
        /// Клиент OAuth, которому выдан токен, — из поля aud в id_token.
        let clientID: String?
        let email: String?
    }

    static func parseCredentials(_ data: Data) throws -> Credentials {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = root["token"] as? [String: Any]
        else { throw FetchError.notLoggedIn }
        let claims = claims(ofIDToken: root["id_token"] as? String)
        let credentials = Credentials(
            accessToken: text(token["access_token"]),
            refreshToken: text(token["refresh_token"]),
            expiresAt: (token["expiry"] as? String).flatMap(date),
            clientID: text(claims["aud"]),
            email: text(claims["email"])
        )
        guard credentials.accessToken != nil || credentials.refreshToken != nil else { throw FetchError.notLoggedIn }
        return credentials
    }

    static func readCredentials() throws -> Credentials {
        guard let data = try? Data(contentsOf: tokenFile) else { throw FetchError.notLoggedIn }
        return try parseCredentials(data)
    }

    static func needsRefresh(expiresAt: Date?, now: Date = .now) -> Bool {
        guard let expiresAt else { return true }
        return expiresAt.timeIntervalSince(now) <= 60
    }

    private static func claims(ofIDToken token: String?) -> [String: Any] {
        guard let parts = token?.split(separator: "."), parts.count >= 2 else { return [:] }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: - Обновление токена

    enum RefreshOutcome: Equatable {
        case token(String, expiresAt: Date)
        /// Служебный пароль не от этого клиента — пробуем следующий.
        case wrongClient
        case rejected
    }

    static func refreshRequest(clientID: String, clientSecret: String, refreshToken: String) -> URLRequest {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let fields = [
            ("client_id", clientID), ("client_secret", clientSecret),
            ("refresh_token", refreshToken), ("grant_type", "refresh_token"),
        ]
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.httpShouldHandleCookies = false
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(fields
            .map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").utf8)
        return request
    }

    static func parseRefresh(status: Int, data: Data, now: Date = .now) -> RefreshOutcome {
        let root = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if status == 200, let token = text(root["access_token"]) {
            let lifetime = (root["expires_in"] as? NSNumber)?.doubleValue ?? 0
            return .token(token, expiresAt: now + lifetime)
        }
        return root["error"] as? String == "invalid_client" ? .wrongClient : .rejected
    }

    /// Программы, в которых Antigravity хранит служебный пароль своего клиента OAuth.
    static var clientSecretArtifacts: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let bundle = "Antigravity.app/Contents/Resources/bin/language_server"
        return [
            URL(fileURLWithPath: "/Applications/\(bundle)"),
            home.appendingPathComponent("Applications/\(bundle)"),
            home.appendingPathComponent(".local/bin/agy"),
        ]
    }

    static func clientSecrets(in data: Data) -> [String] {
        let marker = Data("GOCSPX-".utf8)
        var found: [String] = []
        var search = data.startIndex..<data.endIndex
        while let match = data.range(of: marker, in: search) {
            search = match.upperBound..<data.endIndex
            let end = match.upperBound + 28
            guard end <= data.endIndex,
                  data[match.upperBound..<end].allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 45 || $0 == 95 })
            else { continue }
            let secret = String(decoding: data[match.lowerBound..<end], as: UTF8.self)
            if !found.contains(secret) { found.append(secret) }
        }
        return found
    }

    static func installedClientSecrets() -> [String] {
        for url in clientSecretArtifacts {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
            let secrets = clientSecrets(in: data)
            if !secrets.isEmpty { return secrets }
        }
        return []
    }

    // MARK: - Запросы

    static func apiRequest(_ method: String, accessToken: String, body: [String: Any]) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://cloudcode-pa.googleapis.com/v1internal:\(method)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func error(forStatus status: Int) -> FetchError {
        switch status {
        case 401: .sessionExpired
        case 403: .forbidden
        case 429: .rateLimited
        default: .server(status)
        }
    }

    /// Проект Google Cloud аккаунта и название тарифа. Как в Gemini CLI: paidTier.name, а без него currentTier.
    static func parseCodeAssist(_ data: Data) -> (project: String?, plan: String?) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (nil, nil) }
        let reference = root["cloudaicompanionProject"]
        let project = text(reference) ?? text((reference as? [String: Any])?["id"]) ?? text((reference as? [String: Any])?["projectId"])
        let tier = root["currentTier"] as? [String: Any]
        let tiers = ["standard-tier": "Paid", "free-tier": "Free", "legacy-tier": "Legacy"]
        let plan = text((root["planInfo"] as? [String: Any])?["planType"])
            ?? text((root["paidTier"] as? [String: Any])?["name"])
            ?? text(tier?["id"]).flatMap { tiers[$0] }
            ?? text(tier?["name"])
        return (project, plan.map { String($0.prefix(40)) })
    }

    // MARK: - Сводка квоты

    private enum Cadence: Int {
        case session, weekly, other
    }

    /// Разбор вывода `agy -p "/usage" --output-format json`.
    /// Поддерживает префиксные строки лога перед JSON и ошибки в поле status/error/stderr.
    static func parseCLIUsage(_ data: Data, exitCode: Int32 = 0, stderr: String = "", now: Date = .now) throws -> UsageSnapshot {
        let root = jsonObject(in: data)
        if let root {
            if let status = text(root["status"])?.uppercased(), status != "SUCCESS" {
                let message = [text(root["error"]), text(root["message"]), text(root["response"]), text(stderr)]
                    .compactMap { $0 }.joined(separator: "\n")
                throw cliError(message: message)
            }
            if let command = root["command"] as? [String: Any], let payload = command["data"] as? [String: Any] {
                var snapshot = try parseQuotaSummaryPayload(payload, now: now)
                snapshot.plan = planName(in: payload) ?? planName(in: root)
                return snapshot
            }
            if root["groups"] != nil || root["response"] is [String: Any] || root["summary"] is [String: Any] {
                let payload = root["response"] as? [String: Any] ?? root["summary"] as? [String: Any] ?? root
                var snapshot = try parseQuotaSummaryPayload(payload, now: now)
                snapshot.plan = planName(in: payload) ?? planName(in: root)
                return snapshot
            }
            if exitCode != 0 {
                let message = [text(root["error"]), text(root["message"]), text(root["response"]), text(stderr)]
                    .compactMap { $0 }.joined(separator: "\n")
                throw cliError(message: message)
            }
            throw FetchError.invalidResponse
        }
        if exitCode != 0 {
            let stdout = String(decoding: data, as: UTF8.self)
            throw cliError(message: "\(stdout)\n\(stderr)")
        }
        throw FetchError.invalidResponse
    }

    static func cliError(message: String) -> FetchError {
        let lowered = message.lowercased()
        if lowered.contains("not logged in") || lowered.contains("sign in") || lowered.contains("authentication required")
            || lowered.contains("unauthenticated") || lowered.contains("login") || lowered.contains("credential")
            || lowered.contains("oauth") || lowered.contains("token") {
            return .sessionExpired
        }
        if lowered.contains("429") || lowered.contains("rate limit") || lowered.contains("too many requests") {
            return .rateLimited
        }
        if lowered.contains("403") || lowered.contains("forbidden") || lowered.contains("permission") {
            return .forbidden
        }
        if lowered.contains("no quota") || lowered.contains("gemini_api_key") || lowered.contains("no account quota") {
            return .noLimits
        }
        return .invalidResponse
    }

    /// Группа «Gemini Models» даёт окна сеанса и недели, остальные группы
    /// (Claude/GPT, отдельные модели вроде «Gemini 4 Argon») — окна со своей подписью,
    /// как в `/usage` и окне квот Antigravity.
    static func parseQuotaSummary(_ data: Data, now: Date = .now) throws -> UsageSnapshot {
        guard let root = jsonObject(in: data) else { throw FetchError.invalidResponse }
        let payload = (root["command"] as? [String: Any])?["data"] as? [String: Any]
            ?? root["response"] as? [String: Any]
            ?? root["summary"] as? [String: Any]
            ?? root
        return try parseQuotaSummaryPayload(payload, now: now)
    }

    private static func parseQuotaSummaryPayload(_ payload: [String: Any], now: Date) throws -> UsageSnapshot {
        guard let groups = payload["groups"] as? [[String: Any]] else { throw FetchError.invalidResponse }

        var windows: [UsageWindow] = []
        var details: [UsageDetail] = []
        var hasPrimaryGemini = false
        for group in groups.prefix(20) {
            let name = text(group["displayName"]) ?? text(group["name"]) ?? "Квота"
            let rawBuckets = (group["buckets"] as? [[String: Any]] ?? []).prefix(20)
            let lowered = name.lowercased()
            let isPrimaryGemini = !hasPrimaryGemini && isPrimaryGeminiGroup(name: lowered, buckets: rawBuckets)
            if isPrimaryGemini { hasPrimaryGemini = true }
            let label = isPrimaryGemini ? "Gemini" : (lowered.contains("claude") ? "Claude/GPT" : name)
            let buckets = rawBuckets.compactMap { bucket -> (Cadence, UsageWindow)? in
                guard bucket["disabled"] as? Bool != true, let remaining = remainingFraction(bucket) else { return nil }
                let title = text(bucket["displayName"]) ?? text(bucket["name"]) ?? text(bucket["bucketId"]) ?? text(bucket["id"]) ?? "лимит"
                let cadence = cadence(of: bucket)
                let kind: UsageWindow.Kind
                let duration: TimeInterval
                switch cadence {
                case .session:
                    kind = isPrimaryGemini ? .session : .custom("\(label) · 5 часов")
                    duration = 5 * 3600
                case .weekly:
                    kind = isPrimaryGemini ? .weekly : .custom("\(label) · неделя")
                    duration = 7 * 86_400
                case .other:
                    kind = .custom("\(label) · \(title)")
                    duration = 0
                }
                let resetRaw = (bucket["resetTime"] as? String) ?? (bucket["reset_time"] as? String)
                let window = UsageWindow(
                    kind: kind, percent: (1 - remaining) * 100,
                    resetsAt: resetRaw.flatMap(date), duration: duration
                )
                return (cadence, window)
            }
            for (_, window) in buckets.sorted(by: { $0.0.rawValue < $1.0.rawValue }) where !windows.contains(where: { $0.kind == window.kind }) {
                windows.append(window)
            }
            if !buckets.isEmpty, let description = text(group["description"]) {
                let prefix = "Models within this group: "
                if description.hasPrefix(prefix) {
                    let models = String(description.dropFirst(prefix.count))
                    if !models.isEmpty {
                        details.append(UsageDetail(label: String(name.prefix(60)), value: String(models.prefix(160))))
                    }
                }
            }
        }
        guard !windows.isEmpty else { throw FetchError.noLimits }
        var snapshot = UsageSnapshot(windows: windows, fetchedAt: now)
        snapshot.details = details
        return snapshot
    }

    /// Основной общий пул Gemini («Gemini Models» или «Gemini»), в отличие от отдельных
    /// модельных групп вроде «Gemini 4 Argon», которые не должны перебивать .session/.weekly.
    private static func isPrimaryGeminiGroup(name lowered: String, buckets: ArraySlice<[String: Any]>) -> Bool {
        if lowered == "gemini models" || lowered == "gemini" { return true }
        if lowered.contains("gemini") && lowered.contains("model") { return true }
        return buckets.contains { bucket in
            let id = (text(bucket["bucketId"]) ?? text(bucket["id"]) ?? "").lowercased()
            return id == "gemini-5h" || id == "gemini-weekly"
        }
    }

    private static func planName(in dictionary: [String: Any]) -> String? {
        let raw = text(dictionary["plan"])
            ?? text((dictionary["planInfo"] as? [String: Any])?["planType"])
            ?? text(dictionary["planType"])
            ?? text(dictionary["plan_type"])
            ?? text(dictionary["tier"])
        return raw.map { String($0.prefix(40)) }
    }

    /// JSON-объект из stdout: сначала целиком, а если перед ним попали строки лога — от первой `{` до последней `}`.
    private static func jsonObject(in data: Data) -> [String: Any]? {
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return root }
        guard let start = data.firstIndex(of: UInt8(ascii: "{")),
              let end = data.lastIndex(of: UInt8(ascii: "}")),
              start < end
        else { return nil }
        return try? JSONSerialization.jsonObject(with: data[start...end]) as? [String: Any]
    }

    /// Запасной ответ retrieveUserQuota: остаток по каждой модели, без деления на сеанс и неделю.
    static func parseQuotaBuckets(_ data: Data, now: Date = .now) throws -> UsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let buckets = root["buckets"] as? [[String: Any]]
        else { throw FetchError.invalidResponse }

        var lowest: [String: (remaining: Double, resetsAt: Date?)] = [:]
        for bucket in buckets.prefix(200) {
            guard let model = text(bucket["modelId"]), let remaining = fraction(bucket["remainingFraction"]) else { continue }
            if let known = lowest[model], known.remaining <= remaining { continue }
            lowest[model] = (remaining, (bucket["resetTime"] as? String).flatMap(date))
        }
        guard !lowest.isEmpty else { throw FetchError.noLimits }
        let windows = lowest.sorted { $0.key < $1.key }.map { model, quota in
            UsageWindow(kind: .custom(String(model.prefix(60))), percent: (1 - quota.remaining) * 100, resetsAt: quota.resetsAt, duration: 0)
        }
        return UsageSnapshot(windows: windows, fetchedAt: now)
    }

    /// Остаток приходит числом (camelCase или snake_case), вложенным объектом или парой case/value.
    private static func remainingFraction(_ bucket: [String: Any]) -> Double? {
        if let direct = fraction(bucket["remainingFraction"]) ?? fraction(bucket["remaining_fraction"]) { return direct }
        guard let remaining = bucket["remaining"] as? [String: Any] else { return nil }
        if let nested = fraction(remaining["remainingFraction"]) ?? fraction(remaining["remaining_fraction"]) { return nested }
        return remaining["case"] as? String == "remainingFraction" ? fraction(remaining["value"]) : nil
    }

    /// Длина окна — по полю window, а без него по идентификатору и названию («gemini-5h», «Weekly Limit Remaining»).
    private static func cadence(of bucket: [String: Any]) -> Cadence {
        let sources = text(bucket["window"]).map { [$0] }
            ?? [text(bucket["bucketId"]), text(bucket["id"]), text(bucket["displayName"]), text(bucket["name"])].compactMap { $0 }
        let session = ["session", "5h", "5-hour", "five hour", "five-hour"]
        var result = Cadence.other
        for source in sources {
            var value = source.lowercased().replacingOccurrences(of: "_", with: "-")
            if value.hasSuffix(" remaining") { value.removeLast(" remaining".count) }
            if value.hasSuffix(" limit") { value.removeLast(" limit".count) }
            if session.contains(where: { value == $0 || value.hasSuffix("-\($0)") || value.hasSuffix(" \($0)") }) { return .session }
            if value == "weekly" || value.hasSuffix("-weekly") || value.hasSuffix(" weekly") { result = .weekly }
        }
        return result
    }

    private static func fraction(_ raw: Any?) -> Double? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        return value.isFinite ? min(1, max(0, value)) : nil
    }

    private static func text(_ raw: Any?) -> String? {
        guard let value = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    /// Время у Google бывает с дробными секундами любой длины — они отбрасываются.
    static func date(_ raw: String) -> Date? {
        ISO8601DateFormatter().date(from: raw.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression))
    }
}

/// Источник для LimitsStore: сначала `agy -p "/usage" --output-format json`,
/// а если CLI не установлен — прежний файл входа Google в ~/.gemini.
final class GeminiLimitsSource: LimitsSource {
    typealias CLIRunner = @Sendable (URL) async throws -> (stdout: Data, stderr: Data, exitCode: Int32)

    private let session = URLSession(configuration: {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return configuration
    }(), delegate: NoRedirects(), delegateQueue: nil)

    private let findCLI: @Sendable () -> URL?
    private let runCLI: CLIRunner

    private var refreshed: (refreshToken: String, accessToken: String, expiresAt: Date)?
    /// Подошедший служебный пароль клиента — чтобы не читать программу Antigravity при каждом обновлении.
    private var clientSecret: String?

    init(
        findCLI: @escaping @Sendable () -> URL? = { GeminiWeb.findCLI() },
        runCLI: @escaping CLIRunner = GeminiLimitsSource.defaultRunCLI
    ) {
        self.findCLI = findCLI
        self.runCLI = runCLI
    }

    func fetch() async throws -> UsageSnapshot {
        if let binary = findCLI() {
            let result = try await runCLI(binary)
            return try GeminiWeb.parseCLIUsage(
                result.stdout,
                exitCode: result.exitCode,
                stderr: String(decoding: result.stderr, as: UTF8.self)
            )
        }
        return try await fetchViaTokenFile()
    }

    private func fetchViaTokenFile() async throws -> UsageSnapshot {
        let credentials = try await Task.detached(priority: .utility) { try GeminiWeb.readCredentials() }.value
        let token = try await accessToken(for: credentials)

        let assist = GeminiWeb.parseCodeAssist(try await post("loadCodeAssist", token: token, body: ["metadata": GeminiWeb.clientMetadata]))
        let body: [String: Any] = assist.project.map { ["project": $0] } ?? [:]
        var snapshot: UsageSnapshot
        do {
            snapshot = try GeminiWeb.parseQuotaSummary(try await post("retrieveUserQuotaSummary", token: token, body: body))
        } catch GeminiWeb.FetchError.sessionExpired {
            throw GeminiWeb.FetchError.sessionExpired
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Сводки нет (старый тариф или аккаунт) — остаток по моделям, как запасной путь у CodexBar.
            snapshot = try GeminiWeb.parseQuotaBuckets(try await post("retrieveUserQuota", token: token, body: body))
        }
        snapshot.plan = assist.plan
        return snapshot
    }

    private nonisolated static func defaultRunCLI(binary: URL) async throws -> (stdout: Data, stderr: Data, exitCode: Int32) {
        let env = GeminiWeb.cliEnvironment(from: ProcessInfo.processInfo.environment, binaryDirectory: binary.deletingLastPathComponent())
        let process = Process()
        process.executableURL = binary
        process.arguments = GeminiWeb.cliArguments
        process.environment = env
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let (exited, signal) = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { finished in
            signal.yield(finished.terminationStatus)
            signal.finish()
        }
        try process.run()

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        return try await withTaskCancellationHandler {
            async let stdout: Data = Task.detached(priority: .utility) {
                (try? stdoutHandle.readToEnd()) ?? Data()
            }.value
            async let stderr: Data = Task.detached(priority: .utility) {
                (try? stderrHandle.readToEnd()) ?? Data()
            }.value
            var exitCode: Int32 = 0
            for await code in exited { exitCode = code }
            let (outData, errData) = await (stdout, stderr)
            if Task.isCancelled { throw CancellationError() }
            return (outData, errData, exitCode)
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    private func post(_ method: String, token: String, body: [String: Any]) async throws -> Data {
        let (data, response) = try await session.data(for: GeminiWeb.apiRequest(method, accessToken: token, body: body))
        guard let http = response as? HTTPURLResponse else { throw GeminiWeb.FetchError.invalidResponse }
        guard http.statusCode == 200 else { throw GeminiWeb.error(forStatus: http.statusCode) }
        return data
    }

    private func accessToken(for credentials: GeminiWeb.Credentials) async throws -> String {
        if let refreshed, refreshed.refreshToken == credentials.refreshToken, !GeminiWeb.needsRefresh(expiresAt: refreshed.expiresAt) {
            return refreshed.accessToken
        }
        if let token = credentials.accessToken, !GeminiWeb.needsRefresh(expiresAt: credentials.expiresAt) { return token }
        guard let refreshToken = credentials.refreshToken, let clientID = credentials.clientID else {
            throw GeminiWeb.FetchError.sessionExpired
        }

        var secrets = [clientSecret].compactMap { $0 }
        if secrets.isEmpty {
            secrets = await Task.detached(priority: .utility) { GeminiWeb.installedClientSecrets() }.value
        }
        for secret in secrets {
            let request = GeminiWeb.refreshRequest(clientID: clientID, clientSecret: secret, refreshToken: refreshToken)
            let (data, response) = try await session.data(for: request)
            switch GeminiWeb.parseRefresh(status: (response as? HTTPURLResponse)?.statusCode ?? 0, data: data) {
            case .token(let token, let expiresAt):
                clientSecret = secret
                refreshed = (refreshToken, token, expiresAt)
                return token
            case .wrongClient:
                continue
            case .rejected:
                throw GeminiWeb.FetchError.sessionExpired
            }
        }
        clientSecret = nil
        throw GeminiWeb.FetchError.clientNotFound
    }
}
