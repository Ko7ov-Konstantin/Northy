import AppKit
import AVFoundation
import IOKit.pwr_mgt
import Observation

/// Системный screencapture: режимы, аргументы и имена файлов. Запись идёт через ScreenRecorder.
nonisolated enum ScreenCapture {
    enum Mode: Equatable, Sendable {
        case area, window, screen, text, recording
    }

    static let executable = URL(fileURLWithPath: "/usr/sbin/screencapture")
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    static func arguments(for mode: Mode, output: URL) -> [String] {
        let flags: [String] = switch mode {
        case .area: ["-i", "-s"]
        case .window: ["-i", "-w"]
        case .screen: ["-m"]
        case .text: ["-i", "-s", "-x"]
        case .recording: preconditionFailure("запись идёт через ScreenRecorder")
        }
        return flags + [output.path]
    }

    static func fileExtension(for mode: Mode) -> String {
        mode == .recording ? "mov" : "png"
    }

    static func fileName(for mode: Mode, date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd 'в' HH.mm.ss"
        let title = mode == .recording ? "Запись" : "Снимок"
        return "\(title) \(formatter.string(from: date)).\(fileExtension(for: mode))"
    }
}

/// Цвет в строку `#RRGGBB`: sRGB, округление, компоненты зажаты в 0…1.
nonisolated enum ColorHex {
    static func string(red: Double, green: Double, blue: Double) -> String {
        let bytes = [red, green, blue].map { Int((min(max($0, 0), 1) * 255).rounded()) }
        return "#" + bytes.map { String(format: "%02X", $0) }.joined()
    }

    static func string(from color: NSColor) -> String? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        return string(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent)
    }
}

/// Запущенный screencapture или идущая запись экрана; в тестах подменяется.
struct CaptureProcess {
    var interrupt: @MainActor () -> Void
    var finished: @MainActor () async -> Void
    /// Блокирующее ожидание выхода — только при завершении приложения.
    var waitUntilExit: @MainActor () -> Void
}

/// Действия вкладки «Инструменты»: снимки, текст с экрана, запись. Одно действие за раз.
@Observable
final class ToolsStore {
    struct Environment {
        var hasPermission: @MainActor () -> Bool = { CGPreflightScreenCaptureAccess() }
        var requestPermission: @MainActor () -> Void = { _ = CGRequestScreenCaptureAccess() }
        var launch: @MainActor ([String]) throws -> CaptureProcess = ToolsStore.launch
        var record: @MainActor (RecordingAudio, RecordingSource, URL) async throws -> CaptureProcess = { try await ScreenRecorder.start(audio: $0, source: $1, output: $2) }
        /// Звук системы и микрофон SCK пишет отдельными дорожками — сводим в одну.
        var mixAudio: @MainActor (URL) async throws -> Void = { try await RecordingAudioMix.mixDown($0) }
        var microphoneStatus: @MainActor () -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for: .audio) }
        var requestMicrophone: @MainActor () async -> Bool = { await AVCaptureDevice.requestAccess(for: .audio) }
        var microphones: @MainActor () -> [AudioInput] = ScreenRecorder.microphones
        var recognize: @MainActor (URL) async throws -> String = { try await TextRecognition.recognizeText(at: $0) }
        var copyImage: @MainActor (URL) -> Void = { url in
            guard let image = NSImage(contentsOf: url) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
        }
        var copyText: @MainActor (String) -> Void = { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        /// Системная пипетка; nil — выбор отменён.
        var pickColor: @MainActor () async -> NSColor? = {
            await withCheckedContinuation { continuation in
                // Пипетку держит замыкание, пока она не ответит.
                nonisolated(unsafe) let sampler = NSColorSampler()
                sampler.show { color in
                    _ = sampler
                    continuation.resume(returning: color)
                }
            }
        }
        /// Выделение области мышью; nil — выбор отменён.
        var pickArea: @MainActor () async -> CGRect? = AreaPicker.pick
        /// Окно под курсором; nil — выбор отменён.
        var pickWindow: @MainActor () async -> CGWindowID? = WindowPicker.pick
        /// Отсчёт перед записью; false — отменён.
        var countdown: @MainActor () async -> Bool = RecordingCountdown.run
        /// nil — система отказала в запрете сна.
        var createSleepAssertion: @MainActor (String) -> IOPMAssertionID? = { reason in
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason as CFString,
                &id
            )
            return result == kIOReturnSuccess ? id : nil
        }
        var releaseSleepAssertion: @MainActor (IOPMAssertionID) -> Void = { _ = IOPMAssertionRelease($0) }
        var temporaryDirectory: URL = FileManager.default.temporaryDirectory
        var dropsDirectory: URL = AppData.dropsDirectory
    }

    enum RecordingKind: Equatable {
        case display, area, window
    }

    enum Activity: Equatable {
        case idle
        case capturing(ScreenCapture.Mode)
        case recording(since: Date)
        /// Запись остановлена, файл дописывается.
        case finishing
        case pickingColor
    }

    private(set) var activity = Activity.idle
    /// Без разрешения «Запись экрана» screencapture молча снимает одни обои.
    private(set) var needsPermission = false
    private(set) var status: String?
    private(set) var recordingTask: Task<Void, Never>?

    /// Убрать панель из кадра и дождаться, пока она свернётся.
    @ObservationIgnored var hidePanel: @MainActor () async -> Void = {}
    /// Готовый файл лёг на полку — панель её коротко показывает.
    @ObservationIgnored var onShelfAdded: @MainActor () -> Void = {}
    /// Плитка «Задать вопрос»: панель сворачивается, открывается окно чата.
    @ObservationIgnored var openChat: @MainActor () -> Void = {}

    @ObservationIgnored private let settings: AppSettings
    /// Скрипт не зависит от activity: запись, снимки и пипетка ему не мешают.
    @ObservationIgnored let script: ScriptRunner
    @ObservationIgnored private let shelf: ShelfStore
    @ObservationIgnored private let environment: Environment
    /// Запрет сна не зависит от activity и не переживает перезапуск.
    private var sleepAssertion: IOPMAssertionID?
    @ObservationIgnored private var recording: (process: CaptureProcess, file: URL)?

    init(shelf: ShelfStore, settings: AppSettings, environment: Environment = Environment(), script: ScriptRunner? = nil) {
        self.script = script ?? ScriptRunner(settings: settings)
        self.shelf = shelf
        self.settings = settings
        self.environment = environment
    }

    var isRecording: Bool {
        if case .recording = activity { true } else { false }
    }

    var isKeepingAwake: Bool { sleepAssertion != nil }

    /// Системная пипетка: цвет уходит в буфер строкой #RRGGBB. Разрешение не нужно.
    func pickColor() async {
        guard begin(.pickingColor, requiresPermission: false) else { return }
        defer { activity = .idle }
        await hidePanel()
        guard let color = await environment.pickColor(), let hex = ColorHex.string(from: color) else { return }
        environment.copyText(hex)
        status = "Цвет \(hex) скопирован"
    }

    func setKeepAwake(_ on: Bool) {
        if on {
            guard sleepAssertion == nil else { return }
            if let id = environment.createSleepAssertion("Northy: не давать уснуть") {
                sleepAssertion = id
            } else {
                status = "Не удалось включить запрет сна"
            }
        } else if let id = sleepAssertion {
            sleepAssertion = nil
            environment.releaseSleepAssertion(id)
        }
    }

    /// Снимок области, окна, экрана или текст с выбранной области.
    func capture(_ mode: ScreenCapture.Mode) async {
        guard mode != .recording, begin(.capturing(mode)) else { return }
        defer { activity = .idle }
        await hidePanel()
        let file = temporaryFile(for: mode)
        do {
            try await environment.launch(ScreenCapture.arguments(for: mode, output: file)).finished()
        } catch {
            status = "Не удалось запустить снимок"
            return
        }
        // Esc при выборе — файла нет, это не ошибка.
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        if mode == .text {
            await recognizeText(in: file)
        } else if let saved = moveToShelf(file, mode: mode) {
            environment.copyImage(saved)
            status = "Снимок на полке и в буфере"
            onShelfAdded()
        } else {
            status = "Не удалось сохранить снимок"
        }
    }

    func startRecording(_ kind: RecordingKind = .display) async {
        guard begin(.capturing(.recording)) else { return }
        guard let audio = await environment.audio(for: settings.recordingAudio) else {
            activity = .idle
            status = "Нет доступа к микрофону — включите его в настройках"
            return
        }
        await hidePanel()
        guard let source = await environment.source(for: kind), await environment.countdown() else {
            activity = .idle
            return
        }
        let file = temporaryFile(for: .recording)
        let process: CaptureProcess
        do {
            process = try await environment.record(audio, source, file)
        } catch {
            try? FileManager.default.removeItem(at: file)
            activity = .idle
            status = "Не удалось начать запись"
            return
        }
        recording = (process, file)
        activity = .recording(since: .now)
        recordingTask = Task {
            await process.finished()
            // Выход из приложения отменяет задачу: там файл уходит на полку без сведения.
            guard !Task.isCancelled, self.recording != nil else { return }
            activity = .finishing
            try? await environment.mixAudio(file)
            finishRecording(showShelf: true)
        }
    }

    func stopRecording() {
        guard isRecording, let recording else { return }
        activity = .finishing
        recording.process.interrupt()
    }

    /// Приложение завершается: запись останавливается, файл успевает лечь на полку.
    func finishForTermination() {
        setKeepAwake(false)
        script.stopForTermination()
        guard let recording else { return }
        if activity != .finishing { recording.process.interrupt() }
        recording.process.waitUntilExit()
        recordingTask?.cancel()
        finishRecording(showShelf: false)
    }

    private func finishRecording(showShelf: Bool) {
        guard let recording else { return }
        self.recording = nil
        activity = .idle
        if moveToShelf(recording.file, mode: .recording) != nil {
            status = "Запись на полке"
            if showShelf { onShelfAdded() }
        } else {
            status = "Запись не сохранилась"
        }
    }

    private func begin(_ next: Activity, requiresPermission: Bool = true) -> Bool {
        guard activity == .idle else { return false }
        guard !requiresPermission || environment.hasPermission() else {
            needsPermission = true
            environment.requestPermission()
            return false
        }
        needsPermission = false
        status = nil
        activity = next
        return true
    }

    private func recognizeText(in file: URL) async {
        defer { try? FileManager.default.removeItem(at: file) }
        status = "Распознаю текст…"
        do {
            environment.copyText(try await environment.recognize(file))
            status = "Текст скопирован в буфер"
        } catch TextRecognition.Failure.noText {
            status = "Текст не найден"
        } catch {
            status = "Не удалось распознать текст"
        }
    }

    private func temporaryFile(for mode: ScreenCapture.Mode) -> URL {
        environment.temporaryDirectory
            .appendingPathComponent("Northy-\(UUID().uuidString).\(ScreenCapture.fileExtension(for: mode))")
    }

    /// Файл переезжает в Drops/<сессия>/ — как дропы полки, чтобы её удаление и очистка убирали и его.
    private func moveToShelf(_ file: URL, mode: ScreenCapture.Mode) -> URL? {
        let session = environment.dropsDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let saved = session.appendingPathComponent(ScreenCapture.fileName(for: mode, date: .now))
        do {
            try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: file, to: saved)
        } catch {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: session)
            return nil
        }
        shelf.add([saved])
        return saved
    }

    static func launch(_ arguments: [String]) throws -> CaptureProcess {
        let process = Process()
        process.executableURL = ScreenCapture.executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let (exited, signal) = AsyncStream<Void>.makeStream()
        process.terminationHandler = { _ in signal.finish() }
        try process.run()
        return CaptureProcess(
            interrupt: { process.interrupt() },
            finished: { for await _ in exited {} },
            waitUntilExit: {
                // Не дольше 5 с: зависший screencapture не должен держать выход из приложения.
                let deadline = Date().addingTimeInterval(5)
                while process.isRunning, Date() < deadline { usleep(50_000) }
            }
        )
    }
}
