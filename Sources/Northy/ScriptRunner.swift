import AppKit
import ApplicationServices
import Observation
import UniformTypeIdentifiers

/// Запущенный скрипт; в тестах подменяется. finished отдаёт код выхода.
struct ScriptProcess {
    var interrupt: @MainActor () -> Void
    var finished: @MainActor () async -> Int32
}

/// Плитка «Скрипт»: запускает и останавливает пользовательский Python-скрипт.
@Observable
final class ScriptRunner {
    struct Environment {
        var launch: @MainActor (URL) throws -> ScriptProcess = ScriptRunner.launch
        var isTrusted: @MainActor () -> Bool = { AXIsProcessTrusted() }
        var requestTrust: @MainActor () -> Void = {
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        /// nil — выбор отменён.
        var pickFile: @MainActor () async -> URL? = ScriptRunner.pickFile
        var fileExists: @MainActor (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    }

    static let interpreter = URL(fileURLWithPath: "/usr/bin/python3")
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    private(set) var status: String?
    private var process: ScriptProcess?

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let environment: Environment
    @ObservationIgnored private var isStopping = false
    @ObservationIgnored private var isChoosing = false

    init(settings: AppSettings, environment: Environment = Environment()) {
        self.settings = settings
        self.environment = environment
    }

    var isRunning: Bool { process != nil }

    var scriptName: String? { settings.scriptPath.map { ($0 as NSString).lastPathComponent } }

    func toggle() async {
        if let process {
            stop(process)
            return
        }
        guard !isChoosing else { return }
        isChoosing = true
        defer { isChoosing = false }
        status = nil
        let path: String
        if let saved = settings.scriptPath, environment.fileExists(saved) {
            path = saved
        } else {
            guard let picked = await environment.pickFile() else { return }
            path = picked.path
            settings.scriptPath = path
        }
        guard environment.isTrusted() else {
            environment.requestTrust()
            status = "Нужно разрешение „Универсальный доступ“ — без него нажатия не дойдут"
            return
        }
        do {
            let process = try environment.launch(URL(fileURLWithPath: path))
            self.process = process
            watch(process)
        } catch {
            status = "Не удалось запустить скрипт"
        }
    }

    func chooseScript() async {
        guard !isRunning, !isChoosing else { return }
        isChoosing = true
        defer { isChoosing = false }
        if let picked = await environment.pickFile() {
            settings.scriptPath = picked.path
        }
    }

    func stopForTermination() {
        if let process { stop(process) }
    }

    private func stop(_ process: ScriptProcess) {
        guard !isStopping else { return }
        isStopping = true
        process.interrupt()
    }

    private func watch(_ process: ScriptProcess) {
        Task {
            let code = await process.finished()
            self.process = nil
            status = code != 0 && !isStopping ? "Скрипт завершился с ошибкой" : nil
            isStopping = false
        }
    }

    private static func launch(_ script: URL) throws -> ScriptProcess {
        let process = Process()
        process.executableURL = interpreter
        process.arguments = [script.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let (exited, signal) = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { finished in
            signal.yield(finished.terminationStatus)
            signal.finish()
        }
        try process.run()
        return ScriptProcess(
            interrupt: { process.interrupt() },
            finished: {
                for await code in exited { return code }
                return 0
            }
        )
    }

    private static func pickFile() async -> URL? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.pythonScript]
        NSApp.activate()
        return await panel.begin() == .OK ? panel.url : nil
    }
}
