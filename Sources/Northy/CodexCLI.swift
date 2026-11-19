import Foundation

nonisolated enum CodexCLI {
    private static let bundledCLI = "ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"

    enum FetchError: LocalizedError, Equatable {
        case missingCLI
        case connection
        case account
        case noWindows
        case timedOut
        case loginFailed

        var errorDescription: String? {
            switch self {
            case .missingCLI: "Codex не найден. Установите приложение Codex или Codex CLI."
            case .connection: "Не удалось подключиться к Codex."
            case .account: "Квоты Codex недоступны. Проверьте вход через ChatGPT в настройках Northy."
            case .noWindows: "Codex не вернул квоты для этого аккаунта."
            case .timedOut: "Codex не ответил вовремя. Обновите лимиты ещё раз."
            case .loginFailed: "Не удалось завершить вход через ChatGPT."
            }
        }
    }

    static var isInstalled: Bool { findBinary() != nil }

    static func findBinary() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            URL(fileURLWithPath: "/Applications").appendingPathComponent(bundledCLI),
            home.appendingPathComponent("Applications").appendingPathComponent(bundledCLI),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
            home.appendingPathComponent(".local/bin/codex"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func fetch(binary: URL, timeout: Duration = .seconds(12)) async throws -> UsageSnapshot {
        let process = makeProcess(binary: binary, arguments: ["app-server"])
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        let writer = input.fileHandleForWriting
        let reader = output.fileHandleForReading
        // Если Codex завершился во время рукопожатия, запись в канал должна вернуть ошибку.
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)

        let (chunks, signal) = AsyncThrowingStream<Data, Error>.makeStream()
        reader.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                signal.finish()
            } else {
                signal.yield(data)
            }
        }
        let timer = Task {
            try await Task.sleep(for: timeout)
            signal.finish(throwing: FetchError.timedOut)
        }
        defer {
            timer.cancel()
            reader.readabilityHandler = nil
            if process.isRunning { process.terminate() }
            try? writer.close()
        }
        do {
            try process.run()
            try writer.write(contentsOf: Self.initialize)
            return try await readSnapshot(chunks, writer: writer)
        } catch let error as FetchError {
            throw error
        } catch {
            throw FetchError.connection
        }
    }

    static func login(binary: URL) async throws {
        let process = makeProcess(binary: binary, arguments: ["login"])
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let (exits, signal) = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { finished in
            signal.yield(finished.terminationStatus)
            signal.finish()
        }
        do {
            try process.run()
        } catch {
            throw FetchError.loginFailed
        }
        defer {
            if process.isRunning { process.terminate() }
        }
        var exit = exits.makeAsyncIterator()
        let status = await exit.next()
        try Task.checkCancellation()
        guard status == 0 else { throw FetchError.loginFailed }
    }

    private static func makeProcess(binary: URL, arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        let path = [binary.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        environment["PATH"] = (path + (environment["PATH"] ?? "").split(separator: ":").map(String.init)).joined(separator: ":")
        process.environment = environment
        return process
    }

    private static let initialize = Data("""
    {"id":0,"method":"initialize","params":{"clientInfo":{"name":"northy","version":"1"}}}

    """.utf8)

    private static let readLimits = Data("""
    {"method":"initialized"}
    {"id":1,"method":"account/rateLimits/read"}

    """.utf8)

    private static func readSnapshot(_ chunks: AsyncThrowingStream<Data, Error>, writer: FileHandle) async throws -> UsageSnapshot {
        var buffer = Data()
        let decoder = JSONDecoder()
        for try await chunk in chunks {
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0a) {
                let line = buffer[..<newline]
                buffer.removeSubrange(...newline)
                guard let reply = try? decoder.decode(Reply.self, from: line) else { continue }
                switch reply.id {
                case 0:
                    guard reply.result != nil else { throw FetchError.connection }
                    try writer.write(contentsOf: readLimits)
                case 1:
                    guard let result = reply.result else { throw FetchError.account }
                    guard let limits = result.rateLimitsByLimitId?["codex"] ?? result.rateLimits else {
                        throw FetchError.noWindows
                    }
                    return try limits.snapshot()
                default:
                    continue
                }
            }
        }
        throw FetchError.connection
    }

    private struct Reply: Decodable {
        struct Result: Decodable {
            let rateLimits: RateLimits?
            let rateLimitsByLimitId: [String: RateLimits]?
        }

        let id: Int
        let result: Result?
    }

    private struct RateLimits: Decodable {
        struct Window: Decodable {
            let usedPercent: Int
            let windowDurationMins: Int?
            let resetsAt: TimeInterval?

            func usage(defaultKind: UsageWindow.Kind, excluding: UsageWindow.Kind? = nil) -> UsageWindow {
                let minutes = windowDurationMins.flatMap { $0 > 0 ? $0 : nil }
                let duration = minutes.map { TimeInterval($0) * 60 }
                let kind: UsageWindow.Kind
                switch minutes {
                case nil where defaultKind != excluding: kind = defaultKind
                case 300 where excluding != .session: kind = .session
                case 10_080 where excluding != .weekly: kind = .weekly
                default:
                    let label = defaultKind == .session ? "Основной лимит" : "Дополнительный лимит"
                    kind = .custom(minutes.map { "\(label) · \($0) мин" } ?? label)
                }
                return UsageWindow(
                    kind: kind, percent: Double(usedPercent),
                    resetsAt: resetsAt.map { Date(timeIntervalSince1970: $0) },
                    duration: duration ?? UsagePace.duration(of: defaultKind)
                )
            }
        }

        let primary: Window?
        let secondary: Window?
        let planType: String?

        func snapshot() throws -> UsageSnapshot {
            let first = primary?.usage(defaultKind: .session)
            let second = secondary?.usage(defaultKind: .weekly, excluding: first?.kind)
            let windows = [first, second].compactMap { $0 }
            guard !windows.isEmpty else { throw FetchError.noWindows }
            let plan = planType == "unknown" ? nil : planType?.replacingOccurrences(of: "_", with: " ").capitalized
            return UsageSnapshot(windows: windows, fetchedAt: .now, plan: plan)
        }
    }
}

struct CodexLimitsSource: LimitsSource {
    func fetch() async throws -> UsageSnapshot {
        guard let binary = CodexCLI.findBinary() else { throw CodexCLI.FetchError.missingCLI }
        return try await CodexCLI.fetch(binary: binary)
    }
}
