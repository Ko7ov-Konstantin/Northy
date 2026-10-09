import Foundation
import Testing
@testable import Northy

/// Чат с Claude: разбор потока `claude -p --output-format stream-json`, аргументы, окружение и стор.
/// Строки потока сняты с настоящего Claude Code 2.1.295 (сокращены); процесс подменён.
@MainActor
struct ClaudeChatTests {
    private static let sessionID = "e22b210f-c6db-42a5-9b65-5979a5edd4a3"
    private static let initLine = #"{"type":"system","subtype":"init","session_id":"e22b210f-c6db-42a5-9b65-5979a5edd4a3","tools":["WebFetch","WebSearch"],"model":"claude-haiku-5-5"}"#
    private static let searchLine = #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_01","name":"WebSearch","input":{}}},"session_id":"e22b210f-c6db-42a5-9b65-5979a5edd4a3"}"#
    private static let fetchLine = #"{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_02","name":"WebFetch","input":{}}}}"#

    private static func delta(_ text: String) -> String {
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\#(text)"}},"session_id":"e22b210f-c6db-42a5-9b65-5979a5edd4a3"}"#
    }

    private static func result(_ text: String, isError: Bool = false) -> String {
        #"{"type":"result","subtype":"success","is_error":\#(isError),"result":"\#(text)","session_id":"e22b210f-c6db-42a5-9b65-5979a5edd4a3"}"#
    }

    // MARK: Разбор потока

    @Test func parsesInitAsSessionStart() {
        #expect(ClaudeCLI.parse(line: Self.initLine) == .sessionStarted(Self.sessionID))
    }

    @Test func parsesTextDelta() {
        #expect(ClaudeCLI.parse(line: Self.delta("Привет")) == .textDelta("Привет"))
    }

    @Test func parsesWebToolStartAsSearching() {
        #expect(ClaudeCLI.parse(line: Self.searchLine) == .searching)
        #expect(ClaudeCLI.parse(line: Self.fetchLine) == .searching)
    }

    @Test func parsesResult() {
        #expect(ClaudeCLI.parse(line: Self.result("Готово")) == .finished(text: "Готово", isError: false))
        #expect(ClaudeCLI.parse(line: Self.result("Нет доступа к модели", isError: true)) == .finished(text: "Нет доступа к модели", isError: true))
    }

    @Test func skipsEverythingElse() {
        let skipped = [
            #"{"type":"assistant","message":{"model":"claude-haiku-5-5","role":"assistant","content":[{"type":"text","text":"Привет"}]}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_01","type":"tool_result","content":"Web search results"}]}}"#,
            #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","rateLimitType":"five_hour"}}"#,
            #"{"type":"system","subtype":"status","status":"requesting","session_id":"e22b210f-c6db-42a5-9b65-5979a5edd4a3"}"#,
            #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"","estimated_tokens":50}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":""}}}"#,
            #"{"type":"stream_event","event":{"type":"message_stop"}}"#,
            "",
            "   ",
            "Warning: Advisor disabled",
        ]
        for line in skipped {
            #expect(ClaudeCLI.parse(line: line) == nil, "\(line)")
        }
    }

    // MARK: Аргументы и окружение

    @Test func firstQuestionArguments() {
        let arguments = ClaudeCLI.arguments(question: "Найди курс евро", model: .opus, effort: .medium, sessionID: nil)
        #expect(arguments.first == "-p")
        #expect(arguments[1] == "Найди курс евро")
        for pair in [
            ["--model", "opus"], ["--effort", "medium"], ["--tools", "WebSearch,WebFetch"],
            ["--allowedTools", "WebSearch,WebFetch"], ["--permission-mode", "dontAsk"], ["--output-format", "stream-json"],
        ] {
            let index = arguments.firstIndex(of: pair[0])
            #expect(index != nil && arguments[index! + 1] == pair[1], "\(pair[0])")
        }
        for flag in ["--safe-mode", "--verbose", "--include-partial-messages"] {
            #expect(arguments.contains(flag), "\(flag)")
        }
        #expect(!arguments.contains("--resume"))
    }

    @Test func awkwardQuestionStaysOneArgument() {
        for question in ["--help", "\"quoted\" and 'single'", "первая строка\nвторая строка"] {
            let arguments = ClaudeCLI.arguments(question: question, model: .haiku, effort: .low, sessionID: nil)
            let index = arguments.firstIndex(of: "-p")!
            // Вопрос не должен читаться как опция; пробел впереди не меняет смысла для модели.
            #expect(arguments[index + 1].trimmingCharacters(in: .whitespaces) == question)
            #expect(!arguments[index + 1].hasPrefix("-"))
            #expect(arguments.count == ClaudeCLI.arguments(question: "x", model: .haiku, effort: .low, sessionID: nil).count)
        }
    }

    @Test func nextQuestionResumesSession() {
        let arguments = ClaudeCLI.arguments(question: "А ещё?", model: .sonnet, effort: .high, sessionID: Self.sessionID)
        let index = arguments.firstIndex(of: "--resume")
        #expect(index != nil && arguments[index! + 1] == Self.sessionID)
    }

    @Test func environmentDropsKeysAndKeepsRest() {
        let base = ["ANTHROPIC_API_KEY": "k", "ANTHROPIC_AUTH_TOKEN": "t", "HOME": "/Users/x", "PATH": "/usr/sbin"]
        let environment = ClaudeCLI.environment(from: base, binaryDirectory: URL(fileURLWithPath: "/Users/x/.local/bin"))
        #expect(environment["ANTHROPIC_API_KEY"] == nil)
        #expect(environment["ANTHROPIC_AUTH_TOKEN"] == nil)
        #expect(environment["HOME"] == "/Users/x")
        let path = environment["PATH", default: ""].split(separator: ":").map(String.init)
        #expect(path.contains("/Users/x/.local/bin"))
        #expect(path.contains("/usr/bin") && path.contains("/bin"))
    }

    @Test func projectDirectoryNameReplacesNonAlphanumerics() {
        let work = URL(fileURLWithPath: "/Users/a.b/Library/Application Support/Northy/Chat/Work")
        #expect(ClaudeCLI.projectDirectoryName(for: work) == "-Users-a-b-Library-Application-Support-Northy-Chat-Work")
    }

    // MARK: Стор

    @MainActor private final class FakeClaude {
        var binary: URL? = URL(fileURLWithPath: "/Users/x/.local/bin/claude")
        var launchFails = false
        private(set) var launches: [(binary: URL, arguments: [String], environment: [String: String], directory: URL)] = []
        private(set) var interrupts = 0
        private var continuations: [AsyncStream<String>.Continuation] = []

        func launch(_ binary: URL, _ arguments: [String], _ environment: [String: String], _ directory: URL) throws -> ChatProcess {
            if launchFails { throw CocoaError(.fileNoSuchFile) }
            launches.append((binary, arguments, environment, directory))
            let (lines, continuation) = AsyncStream<String>.makeStream()
            continuations.append(continuation)
            return ChatProcess(lines: lines, interrupt: { [self] in interrupts += 1 })
        }

        /// Строки приходят от последнего запущенного процесса, если не указан другой.
        func emit(_ lines: String..., from index: Int? = nil) {
            for line in lines { continuations[index ?? continuations.count - 1].yield(line) }
        }

        func exit(index: Int? = nil) {
            continuations[index ?? continuations.count - 1].finish()
        }
    }

    @MainActor private struct Fixture {
        let claude = FakeClaude()
        let settings: AppSettings
        let chatDirectory: URL
        let projectsDirectory: URL
        let defaultsName = "ClaudeChatTests-\(UUID().uuidString)"

        init() throws {
            settings = AppSettings(defaults: UserDefaults(suiteName: defaultsName)!)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeChatTests-\(UUID().uuidString)", isDirectory: true)
            chatDirectory = root.appendingPathComponent("Chat", isDirectory: true)
            projectsDirectory = root.appendingPathComponent("projects", isDirectory: true)
            try FileManager.default.createDirectory(at: chatDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: projectsDirectory, withIntermediateDirectories: true)
        }

        func makeStore() -> ClaudeChatStore {
            let claude = claude
            return ClaudeChatStore(settings: settings, environment: .init(
                findBinary: { claude.binary },
                launch: { try claude.launch($0, $1, $2, $3) },
                processEnvironment: ["ANTHROPIC_API_KEY": "secret", "HOME": "/Users/x"],
                chatDirectory: chatDirectory,
                projectsDirectory: projectsDirectory
            ))
        }

        /// Каталог проекта чата в «~/.claude/projects»: имя зависит от рабочего каталога запуска.
        func projectDirectory() throws -> URL {
            let work = try #require(claude.launches.first?.directory)
            let dir = projectsDirectory.appendingPathComponent(ClaudeCLI.projectDirectoryName(for: work), isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
    }

    /// Ждёт, пока выполнится условие (задачи стора идут на главном акторе).
    private func until(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { try? await Task.sleep(for: .milliseconds(2)) }
    }

    @Test func exchangeGrowsAnswerAndEndsWithResultText() async throws {
        let fixture = try Fixture()
        let store = fixture.makeStore()
        store.send("Привет")
        #expect(store.isAnswering)
        #expect(store.messages.map(\.role) == [.user, .assistant])
        #expect(store.messages.first?.text == "Привет")
        await until { fixture.claude.launches.count == 1 }

        fixture.claude.emit(Self.initLine, Self.delta("При"))
        await until { store.messages.last?.text == "При" }
        #expect(store.messages.last?.text == "При")
        fixture.claude.emit(Self.delta("вет!"))
        await until { store.messages.last?.text == "Привет!" }
        #expect(store.messages.last?.text == "Привет!")
        #expect(store.isAnswering)

        fixture.claude.emit(Self.result("Привет! Чем помочь?"))
        fixture.claude.exit()
        await until { !store.isAnswering }
        #expect(!store.isAnswering)
        #expect(store.messages.map(\.text) == ["Привет", "Привет! Чем помочь?"])
        #expect(store.messages.map(\.role) == [.user, .assistant])
    }

    @Test func launchUsesBinaryEnvironmentAndWorkDirectory() async throws {
        let fixture = try Fixture()
        let store = fixture.makeStore()
        store.send("Вопрос")
        await until { fixture.claude.launches.count == 1 }
        let launch = try #require(fixture.claude.launches.first)
        #expect(launch.binary.path == "/Users/x/.local/bin/claude")
        #expect(launch.environment["ANTHROPIC_API_KEY"] == nil)
        #expect(launch.environment["HOME"] == "/Users/x")
        #expect(launch.environment["PATH", default: ""].contains("/Users/x/.local/bin"))
        #expect(launch.directory.path.hasPrefix(fixture.chatDirectory.path))
        #expect(launch.directory != fixture.chatDirectory)
        #expect(launch.arguments.contains("Вопрос"))
    }

    @Test func emptyAndParallelQuestionsAreNotSent() async throws {
        let fixture = try Fixture()
        let store = fixture.makeStore()
        store.send("")
        store.send("  \n ")
        #expect(store.messages.isEmpty)
        #expect(!store.isAnswering)

        store.send("Первый")
        store.send("Второй")
        await until { fixture.claude.launches.count >= 1 }
        try? await Task.sleep(for: .milliseconds(30))
        #expect(fixture.claude.launches.count == 1)
        #expect(store.messages.map(\.text) == ["Первый", ""])
    }

    @Test func modelAndEffortChangeKeepSession() async throws {
        let fixture = try Fixture()
        let store = fixture.makeStore()
        store.send("Первый")
        await until { fixture.claude.launches.count == 1 }
        fixture.claude.emit(Self.initLine, Self.result("Ответ"))
        fixture.claude.exit()
        await until { !store.isAnswering }

        store.model = .sonnet
        store.effort = .high
        store.send("Второй")
        await until { fixture.claude.launches.count == 2 }
        let first = try #require(fixture.claude.launches.first).arguments
        let second = try #require(fixture.claude.launches.last).arguments
        #expect(!first.contains("--resume"))
        #expect(first.contains("opus") && first.contains("medium"))
        let model = try #require(second.firstIndex(of: "--model"))
        let effort = try #require(second.firstIndex(of: "--effort"))
        let resume = try #require(second.firstIndex(of: "--resume"))
        #expect(second[model + 1] == "sonnet")
        #expect(second[effort + 1] == "high")
        #expect(second[resume + 1] == Self.sessionID)
    }

    @Test func errorResultBecomesErrorMessageAndChatContinues() async throws {
        let fixture = try Fixture()
        let store = fixture.makeStore()
        store.send("Вопрос")
        await until { fixture.claude.launches.count == 1 }
        fixture.claude.emit(Self.initLine, Self.result("There is an issue with the selected model", isError: true))
        fixture.claude.exit()
        await until { !store.isAnswering }
        #expect(!store.isAnswering)
        #expect(store.messages.map(\.role) == [.user, .error])
        #expect(store.messages.last?.text == "There is an issue with the selected model")

        store.send("Ещё раз")
        await until { fixture.claude.launches.count == 2 }
        #expect(fixture.claude.launches.count == 2)
    }

    @Test func processEndingWithoutResultIsAnError() async throws {
        let fixture = try Fixture()
        let store = fixture.makeStore()
        store.send("Вопрос")
        await until { fixture.claude.launches.count == 1 }
        fixture.claude.exit()
        await until { !store.isAnswering }
        #expect(store.messages.map(\.role) == [.user, .error])
        #expect(store.messages.last?.text == "Не удалось получить ответ")
    }

    @Test func launchFailureIsAnError() async throws {
        let fixture = try Fixture()
        fixture.claude.launchFails = true
        let store = fixture.makeStore()
        store.send("Вопрос")
        await until { !store.isAnswering }
        #expect(store.messages.last?.role == .error)
        #expect(store.messages.last?.text == "Не удалось получить ответ")
    }

    @Test func missingBinaryIsAnErrorWithoutLaunch() async throws {
        let fixture = try Fixture()
        fixture.claude.binary = nil
        let store = fixture.makeStore()
        store.send("Вопрос")
        await until { !store.isAnswering }
        #expect(store.messages.map(\.role) == [.user, .error])
        #expect(store.messages.last?.text == "Claude Code не найден")
        #expect(fixture.claude.launches.isEmpty)
    }

    @Test func stopInterruptsOnceAndKeepsReceivedText() async throws {
        let fixture = try Fixture()
        let store = fixture.makeStore()
        store.send("Вопрос")
        await until { fixture.claude.launches.count == 1 }
        fixture.claude.emit(Self.initLine, Self.delta("Начало"))
        await until { store.messages.last?.text == "Начало" }

        store.stop()
        store.stop()
        #expect(fixture.claude.interrupts == 1)
        fixture.claude.exit()
        await until { !store.isAnswering }
        #expect(!store.isAnswering)
        #expect(store.messages.map(\.text) == ["Вопрос", "Начало"])
        #expect(store.messages.map(\.role) == [.user, .assistant])
    }

    @Test func searchingLastsUntilNextTextOrEnd() async throws {
        let fixture = try Fixture()
        let store = fixture.makeStore()
        store.send("Найди")
        await until { fixture.claude.launches.count == 1 }
        fixture.claude.emit(Self.initLine, Self.searchLine)
        await until { store.isSearching }
        #expect(store.isSearching)

        fixture.claude.emit(Self.delta("Нашёл"))
        await until { !store.isSearching }
        #expect(!store.isSearching)

        fixture.claude.emit(Self.fetchLine)
        await until { store.isSearching }
        #expect(store.isSearching)
        fixture.claude.emit(Self.result("Итог"))
        fixture.claude.exit()
        await until { !store.isAnswering }
        #expect(!store.isSearching)
    }

    @Test func historyAndSessionSurviveRecreation() async throws {
        let fixture = try Fixture()
        let store = fixture.makeStore()
        store.send("Вопрос")
        await until { fixture.claude.launches.count == 1 }
        fixture.claude.emit(Self.initLine, Self.result("Ответ"))
        fixture.claude.exit()
        await until { !store.isAnswering }

        let restored = fixture.makeStore()
        #expect(restored.messages.map(\.text) == ["Вопрос", "Ответ"])
        #expect(restored.messages.map(\.role) == [.user, .assistant])
        restored.send("Ещё")
        await until { fixture.claude.launches.count == 2 }
        let arguments = try #require(fixture.claude.launches.last).arguments
        let resume = try #require(arguments.firstIndex(of: "--resume"))
        #expect(arguments[resume + 1] == Self.sessionID)
    }

    @Test func deleteSessionRemovesHistoryAndOwnSessionFilesOnly() async throws {
        let fixture = try Fixture()
        let store = fixture.makeStore()
        store.send("Вопрос")
        await until { fixture.claude.launches.count == 1 }
        fixture.claude.emit(Self.initLine, Self.result("Ответ"))
        fixture.claude.exit()
        await until { !store.isAnswering }

        let project = try fixture.projectDirectory()
        let own = project.appendingPathComponent("\(Self.sessionID).jsonl")
        let ownFolder = project.appendingPathComponent(Self.sessionID, isDirectory: true)
        let foreign = project.appendingPathComponent("11111111-2222-3333-4444-555555555555.jsonl")
        try Data("{}".utf8).write(to: own)
        try FileManager.default.createDirectory(at: ownFolder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: ownFolder.appendingPathComponent("tool-results.json"))
        try Data("{}".utf8).write(to: foreign)
        func historyFiles() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: fixture.chatDirectory.path)) ?? []).filter { $0.hasSuffix(".json") }
        }
        #expect(!historyFiles().isEmpty)

        store.deleteSession()
        #expect(store.messages.isEmpty)
        #expect(historyFiles().isEmpty)
        // Задача только что закрытого запуска ещё доходит до конца: файлы уходят сразу после неё.
        await until { !FileManager.default.fileExists(atPath: own.path) }
        #expect(!FileManager.default.fileExists(atPath: own.path))
        #expect(!FileManager.default.fileExists(atPath: ownFolder.path))
        #expect(FileManager.default.fileExists(atPath: foreign.path))

        store.send("Новый")
        await until { fixture.claude.launches.count == 2 }
        #expect(try #require(fixture.claude.launches.last).arguments.contains("--resume") == false)
    }

    @Test func deleteSessionIgnoresIdThatIsNotUUID() async throws {
        let fixture = try Fixture()
        let store = fixture.makeStore()
        store.send("Вопрос")
        await until { fixture.claude.launches.count == 1 }
        let evil = #"{"type":"system","subtype":"init","session_id":"../../x"}"#
        fixture.claude.emit(evil, Self.result("Ответ"))
        fixture.claude.exit()
        await until { !store.isAnswering }

        let project = try fixture.projectDirectory()
        let neighbour = project.appendingPathComponent("11111111-2222-3333-4444-555555555555.jsonl")
        let outside = fixture.projectsDirectory.deletingLastPathComponent().appendingPathComponent("x.jsonl")
        let outsideFolder = fixture.projectsDirectory.deletingLastPathComponent().appendingPathComponent("x", isDirectory: true)
        try Data("{}".utf8).write(to: neighbour)
        try Data("{}".utf8).write(to: outside)
        try FileManager.default.createDirectory(at: outsideFolder, withIntermediateDirectories: true)

        store.deleteSession()
        #expect(store.messages.isEmpty)
        #expect(FileManager.default.fileExists(atPath: neighbour.path))
        #expect(FileManager.default.fileExists(atPath: outside.path))
        #expect(FileManager.default.fileExists(atPath: outsideFolder.path))
        #expect(FileManager.default.fileExists(atPath: project.path))
        let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: fixture.chatDirectory.path)) ?? []).filter { $0.hasSuffix(".json") }
        #expect(leftovers.isEmpty)
    }

    @Test func deleteSessionDuringAnswerDropsLateEvents() async throws {
        let fixture = try Fixture()
        let store = fixture.makeStore()
        store.send("Вопрос")
        await until { fixture.claude.launches.count == 1 }
        fixture.claude.emit(Self.initLine, Self.delta("Часть"))
        await until { store.messages.last?.text == "Часть" }

        store.deleteSession()
        #expect(fixture.claude.interrupts == 1)
        #expect(store.messages.isEmpty)
        #expect(!store.isAnswering)

        fixture.claude.emit(Self.delta("Запоздавший текст"), Self.result("Запоздавший итог"), from: 0)
        fixture.claude.exit(index: 0)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(store.messages.isEmpty)
        #expect(!store.isAnswering)
    }

    @Test func deleteSessionDuringAnswerDoesNotBreakNextQuestion() async throws {
        let fixture = try Fixture()
        let store = fixture.makeStore()
        store.send("Старый")
        await until { fixture.claude.launches.count == 1 }
        store.deleteSession()
        store.send("Новый")
        await until { fixture.claude.launches.count == 2 }
        // Старый процесс заканчивается уже после запуска нового.
        fixture.claude.exit(index: 0)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(store.isAnswering)
        #expect(store.messages.map(\.text) == ["Новый", ""])
    }

    /// Умирающий claude может дописать файл сессии уже после её удаления — удаление ждёт конца потока.
    @Test func deleteSessionDuringAnswerWaitsForProcessExit() async throws {
        let fixture = try Fixture()
        let store = fixture.makeStore()
        store.send("Вопрос")
        await until { fixture.claude.launches.count == 1 }
        fixture.claude.emit(Self.initLine, Self.delta("Часть"))
        await until { store.messages.last?.text == "Часть" }
        let project = try fixture.projectDirectory()
        let file = project.appendingPathComponent("\(Self.sessionID).jsonl")
        try Data("{}".utf8).write(to: file)

        store.deleteSession()
        try Data("{}".utf8).write(to: file)
        fixture.claude.exit()
        await until { !FileManager.default.fileExists(atPath: file.path) }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func deleteSessionRightAfterResultWaitsForProcessExit() async throws {
        let fixture = try Fixture()
        let store = fixture.makeStore()
        store.send("Вопрос")
        await until { fixture.claude.launches.count == 1 }
        fixture.claude.emit(Self.initLine, Self.result("Ответ"))
        await until { !store.isAnswering }
        #expect(!store.isAnswering)
        let file = try fixture.projectDirectory().appendingPathComponent("\(Self.sessionID).jsonl")
        try Data("{}".utf8).write(to: file)

        store.deleteSession()
        try Data("{}".utf8).write(to: file)
        fixture.claude.exit()
        await until { !FileManager.default.fileExists(atPath: file.path) }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func questionAfterDeleteStartsNewSessionAndKeepsItsFile() async throws {
        let fixture = try Fixture()
        let store = fixture.makeStore()
        store.send("Старый")
        await until { fixture.claude.launches.count == 1 }
        fixture.claude.emit(Self.initLine, Self.result("Ответ"))
        await until { !store.isAnswering }
        let project = try fixture.projectDirectory()
        let oldFile = project.appendingPathComponent("\(Self.sessionID).jsonl")

        store.deleteSession()
        store.send("Новый")
        await until { fixture.claude.launches.count == 2 }
        #expect(try #require(fixture.claude.launches.last).arguments.contains("--resume") == false)
        let newID = "99999999-8888-7777-6666-555555555555"
        let newFile = project.appendingPathComponent("\(newID).jsonl")
        fixture.claude.emit(#"{"type":"system","subtype":"init","session_id":"\#(newID)"}"#, Self.result("Новый ответ"))
        await until { !store.isAnswering }
        try Data("{}".utf8).write(to: newFile)

        try Data("{}".utf8).write(to: oldFile)
        fixture.claude.exit(index: 0)
        await until { !FileManager.default.fileExists(atPath: oldFile.path) }
        #expect(!FileManager.default.fileExists(atPath: oldFile.path))
        #expect(FileManager.default.fileExists(atPath: newFile.path))
        #expect(store.messages.map(\.text) == ["Новый", "Новый ответ"])
    }

    @Test func modelAndEffortDefaultsAndPersistence() throws {
        let fixture = try Fixture()
        #expect(fixture.settings.chatModel == .opus)
        #expect(fixture.settings.chatEffort == .medium)
        fixture.settings.chatModel = .haiku
        fixture.settings.chatEffort = .max
        let again = AppSettings(defaults: UserDefaults(suiteName: fixture.defaultsName)!)
        #expect(again.chatModel == .haiku)
        #expect(again.chatEffort == .max)
    }

    @Test func terminationInterruptsRunningAnswerOnly() async throws {
        let fixture = try Fixture()
        let store = fixture.makeStore()
        store.stopForTermination()
        #expect(fixture.claude.interrupts == 0)

        store.send("Вопрос")
        await until { fixture.claude.launches.count == 1 }
        store.stopForTermination()
        #expect(fixture.claude.interrupts == 1)
    }
}
