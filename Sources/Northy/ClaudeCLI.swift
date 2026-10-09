import Foundation

/// Псевдонимы моделей Claude Code: в командную строку уходят именно они, без версий.
nonisolated enum ChatModel: String, CaseIterable, Sendable {
    case haiku, sonnet, opus, fable

    var title: String { rawValue.capitalized }
}

nonisolated enum ChatEffort: String, CaseIterable, Sendable {
    case low, medium, high, xhigh, max
}

/// То, что нужно чату из потока `claude -p --output-format stream-json`.
nonisolated enum ChatEvent: Equatable, Sendable {
    case sessionStarted(String)
    case textDelta(String)
    /// Модель пошла в интернет (WebSearch или WebFetch).
    case searching
    case finished(text: String, isError: Bool)
}

/// Запущенный `claude`: строки stdout до выхода процесса и прерывание (SIGINT).
struct ChatProcess {
    var lines: AsyncStream<String>
    var interrupt: @MainActor () -> Void
}

/// Командная строка, окружение и разбор потока Claude Code.
nonisolated enum ClaudeCLI {
    private static let webTools = ["WebSearch", "WebFetch"]
    private static let binaryCandidates = [".local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]

    static func parse(line: String) -> ChatEvent? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return nil }
        switch type {
        case "system":
            guard json["subtype"] as? String == "init", let id = json["session_id"] as? String else { return nil }
            return .sessionStarted(id)
        case "stream_event":
            guard let event = json["event"] as? [String: Any] else { return nil }
            switch event["type"] as? String {
            case "content_block_delta":
                guard let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                      let text = delta["text"] as? String else { return nil }
                return .textDelta(text)
            case "content_block_start":
                guard let block = event["content_block"] as? [String: Any], block["type"] as? String == "tool_use",
                      let name = block["name"] as? String, webTools.contains(name) else { return nil }
                return .searching
            default:
                return nil
            }
        case "result":
            return .finished(text: json["result"] as? String ?? "", isError: json["is_error"] as? Bool ?? false)
        default:
            return nil
        }
    }

    static func arguments(question: String, model: ChatModel, effort: ChatEffort, sessionID: String?) -> [String] {
        // Вопрос с дефисом впереди CLI принял бы за опцию.
        let prompt = question.hasPrefix("-") ? " " + question : question
        let tools = webTools.joined(separator: ",")
        var arguments = [
            "-p", prompt, "--model", model.rawValue, "--effort", effort.rawValue,
            "--safe-mode", "--tools", tools, "--allowedTools", tools, "--permission-mode", "dontAsk",
            "--output-format", "stream-json", "--verbose", "--include-partial-messages",
        ]
        if let sessionID { arguments += ["--resume", sessionID] }
        return arguments
    }

    /// Ключи API убираются: с ними `-p` списывает деньги с API вместо подписки.
    static func environment(from base: [String: String], binaryDirectory: URL) -> [String: String] {
        var environment = base
        environment["ANTHROPIC_API_KEY"] = nil
        environment["ANTHROPIC_AUTH_TOKEN"] = nil
        var path = [binaryDirectory.path] + (base["PATH"] ?? "").split(separator: ":").map(String.init)
        for system in ["/usr/bin", "/bin"] where !path.contains(system) { path.append(system) }
        environment["PATH"] = path.joined(separator: ":")
        return environment
    }

    /// Каталог проекта в `~/.claude/projects`: всё, кроме латиницы и цифр, в пути заменяется на «-».
    static func projectDirectoryName(for directory: URL) -> String {
        String(directory.path.unicodeScalars.map { scalar in
            scalar.isASCII && CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        })
    }

    /// У GUI-приложения урезанный PATH, поэтому бинарник ищется по списку.
    static func findBinary() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return binaryCandidates
            .map { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : home.appendingPathComponent($0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    @MainActor
    static func launch(binary: URL, arguments: [String], environment: [String: String], directory: URL) throws -> ChatProcess {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        // Без закрытого stdin CLI ждёт ввод несколько секунд.
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let reader = pipe.fileHandleForReading
        let lines = AsyncStream<String> { continuation in
            let task = Task.detached {
                do {
                    for try await line in reader.bytes.lines { continuation.yield(line) }
                } catch {}
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return ChatProcess(lines: lines, interrupt: { if process.isRunning { process.interrupt() } })
    }
}
