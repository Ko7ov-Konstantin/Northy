import Foundation
import Observation

nonisolated struct ChatMessage: Identifiable, Codable, Equatable {
    enum Role: String, Codable { case user, assistant, error }

    var id = UUID()
    let role: Role
    var text: String
}

/// Быстрый чат с Claude: каждый вопрос — запуск `claude -p`, сессия продолжается через `--resume`.
@Observable
final class ClaudeChatStore {
    struct Environment {
        var findBinary: @MainActor () -> URL? = ClaudeCLI.findBinary
        var launch: @MainActor (URL, [String], [String: String], URL) throws -> ChatProcess = ClaudeCLI.launch
        var processEnvironment = ProcessInfo.processInfo.environment
        /// Здесь лежат история и рабочий каталог запуска `claude`.
        var chatDirectory = AppData.chatDirectory
        var projectsDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)
    }

    private struct History: Codable {
        var messages: [ChatMessage]
        var sessionID: String?
    }

    private(set) var messages: [ChatMessage]
    private(set) var isAnswering = false
    private(set) var isSearching = false
    /// Окно просит вернуть фокус в поле ввода.
    var focusRequest = 0

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let environment: Environment
    @ObservationIgnored private var sessionID: String?
    @ObservationIgnored private var process: ChatProcess?
    @ObservationIgnored private var stopRequested = false
    /// Растёт при каждом вопросе и при удалении сессии: события устаревшего запуска отбрасываются.
    @ObservationIgnored private var generation = 0
    /// Последний запуск живёт, пока не закроется его поток: умирающий claude ещё может писать файл сессии.
    @ObservationIgnored private var lastRun: (number: Int, task: Task<Void, Never>)?
    @ObservationIgnored private var runCount = 0

    init(settings: AppSettings, environment: Environment = Environment()) {
        self.settings = settings
        self.environment = environment
        let history = (try? Data(contentsOf: environment.chatDirectory.appendingPathComponent("history.json")))
            .flatMap { try? JSONDecoder().decode(History.self, from: $0) }
        messages = history?.messages ?? []
        sessionID = history?.sessionID
    }

    var model: ChatModel {
        get { settings.chatModel }
        set { settings.chatModel = newValue }
    }

    var effort: ChatEffort {
        get { settings.chatEffort }
        set { settings.chatEffort = newValue }
    }

    private var historyURL: URL { environment.chatDirectory.appendingPathComponent("history.json") }
    private var workDirectory: URL { environment.chatDirectory.appendingPathComponent("Work", isDirectory: true) }

    func send(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isAnswering else { return }
        messages += [ChatMessage(role: .user, text: question), ChatMessage(role: .assistant, text: "")]
        isAnswering = true
        isSearching = false
        stopRequested = false
        generation += 1
        save()
        let generation = generation
        runCount += 1
        let number = runCount
        let task = Task {
            await run(question, generation: generation)
            if lastRun?.number == number { lastRun = nil }
        }
        lastRun = (number, task)
    }

    func stop() {
        guard isAnswering, !stopRequested else { return }
        stopRequested = true
        process?.interrupt()
    }

    func stopForTermination() {
        guard isAnswering else { return }
        process?.interrupt()
        save()
    }

    /// Стирает ленту, историю и файлы сессии Claude Code; следующий вопрос начнёт новую сессию.
    func deleteSession() {
        generation += 1
        process?.interrupt()
        process = nil
        isAnswering = false
        isSearching = false
        messages = []
        let id = sessionID
        sessionID = nil
        try? FileManager.default.removeItem(at: historyURL)
        let files = sessionFiles(id: id)
        guard let pending = lastRun?.task else { return remove(files) }
        Task {
            await pending.value
            remove(files)
        }
    }

    /// Только файлы сессии с id-UUID внутри каталога проекта чата.
    private func sessionFiles(id: String?) -> [URL] {
        guard let id, let uuid = UUID(uuidString: id)?.uuidString.lowercased() else { return [] }
        let project = environment.projectsDirectory
            .appendingPathComponent(ClaudeCLI.projectDirectoryName(for: workDirectory), isDirectory: true)
            .standardizedFileURL
        return [uuid + ".jsonl", uuid]
            .map { project.appendingPathComponent($0).standardizedFileURL }
            .filter { $0.path.hasPrefix(project.path + "/") }
    }

    private func remove(_ files: [URL]) {
        for file in files { try? FileManager.default.removeItem(at: file) }
    }

    private func run(_ question: String, generation: Int) async {
        guard generation == self.generation else { return }
        let process: ChatProcess
        do {
            guard let binary = environment.findBinary() else { return end("Claude Code не найден") }
            try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
            process = try environment.launch(
                binary,
                ClaudeCLI.arguments(question: question, model: model, effort: effort, sessionID: sessionID),
                ClaudeCLI.environment(from: environment.processEnvironment, binaryDirectory: binary.deletingLastPathComponent()),
                workDirectory
            )
        } catch {
            return end("Не удалось получить ответ")
        }
        self.process = process
        if stopRequested { process.interrupt() }
        // Поток читается до конца процесса и после ответа: по нему удаление сессии узнаёт, что claude вышел.
        var answered = false
        for await line in process.lines {
            guard !answered, generation == self.generation else { continue }
            guard let event = ClaudeCLI.parse(line: line) else { continue }
            switch event {
            case .sessionStarted(let id):
                if sessionID == nil { sessionID = id }
            case .textDelta(let delta):
                isSearching = false
                messages[messages.count - 1].text += delta
            case .searching:
                isSearching = true
            case .finished(let text, let isError):
                answered = true
                if isError { end(text) } else {
                    if !text.isEmpty { messages[messages.count - 1].text = text }
                    end()
                }
            }
        }
        guard !answered, generation == self.generation else { return }
        end(stopRequested ? nil : "Не удалось получить ответ")
    }

    private func end(_ error: String? = nil) {
        let hasEmptyAnswer = messages.last.map { $0.role == .assistant && $0.text.isEmpty } ?? false
        if let error {
            let failure = ChatMessage(role: .error, text: error)
            if hasEmptyAnswer { messages[messages.count - 1] = failure } else { messages.append(failure) }
        } else if hasEmptyAnswer {
            messages.removeLast()
        }
        process = nil
        isAnswering = false
        isSearching = false
        save()
    }

    /// Пустой ответ в историю не попадает: он значит «ещё идёт».
    private func save() {
        let kept = messages.filter { !($0.role == .assistant && $0.text.isEmpty) }
        guard let data = try? JSONEncoder().encode(History(messages: kept, sessionID: sessionID)) else { return }
        try? FileManager.default.createDirectory(at: environment.chatDirectory, withIntermediateDirectories: true)
        try? data.write(to: historyURL, options: .atomic)
    }
}
