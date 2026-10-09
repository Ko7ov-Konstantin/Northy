import AVFoundation
import ScreenCaptureKit

/// Что из звука попадает в запись экрана.
nonisolated struct RecordingAudio: Equatable, Sendable {
    enum Microphone: Hashable, Equatable, Sendable {
        case none, systemDefault, device(String)

        private static let devicePrefix = "device:"

        init(stored: String?) {
            switch stored {
            case "default": self = .systemDefault
            case let value? where value.hasPrefix(Self.devicePrefix): self = .device(String(value.dropFirst(Self.devicePrefix.count)))
            default: self = .none
            }
        }

        var stored: String {
            switch self {
            case .none: "none"
            case .systemDefault: "default"
            case .device(let id): Self.devicePrefix + id
            }
        }
    }

    var systemSound = true
    var microphone = Microphone.none
}

/// Что попадает в кадр. Область — в точках основного дисплея, начало в левом верхнем углу.
nonisolated enum RecordingSource: Equatable, Sendable {
    case display
    case area(CGRect)
    case window(CGWindowID)
}

nonisolated struct AudioInput: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

/// Запись основного дисплея в .mov через ScreenCaptureKit: screencapture звук системы писать не умеет.
enum ScreenRecorder {
    static let microphoneSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!

    static func microphones() -> [AudioInput] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
            .devices.map { AudioInput(id: $0.uniqueID, name: $0.localizedName) }
    }

    static func start(audio: RecordingAudio, source: RecordingSource, output: URL) async throws -> CaptureProcess {
        let content = try await SCShareableContent.current
        let filter: SCContentFilter
        if case .window(let id) = source {
            guard let window = content.windows.first(where: { $0.windowID == id }) else {
                throw CocoaError(.featureUnsupported)
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
        } else {
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else {
                throw CocoaError(.featureUnsupported)
            }
            filter = SCContentFilter(display: display, excludingWindows: [])
        }
        let configuration = SCStreamConfiguration()
        let size: CGSize
        if case .area(let rect) = source {
            configuration.sourceRect = rect
            size = rect.size
        } else {
            size = filter.contentRect.size
        }
        let pixels = AreaSelection.pixelSize(size, scale: CGFloat(filter.pointPixelScale))
        configuration.width = pixels.width
        configuration.height = pixels.height
        configuration.showsCursor = true
        configuration.capturesAudio = audio.systemSound
        // Звук вкладки «Музыка» самого Northy тоже должен попадать в запись.
        configuration.excludesCurrentProcessAudio = false
        configuration.captureMicrophone = audio.microphone != .none
        if case .device(let id) = audio.microphone { configuration.microphoneCaptureDeviceID = id }

        let end = RecordingEnd()
        let stream = SCStream(filter: filter, configuration: configuration, delegate: end)
        let file = SCRecordingOutputConfiguration()
        file.outputURL = output
        file.outputFileType = .mov
        // Свою ссылку держим до конца: иначе по системной кнопке «стоп» SCK уничтожает объект
        // записи раньше, чем делегат узнаёт, что файл дописан, и Northy считает, что запись идёт.
        let recordingOutput = SCRecordingOutput(configuration: file, delegate: end)
        try stream.addRecordingOutput(recordingOutput)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            // @Sendable: SCK зовёт обработчики со своей очереди, главный актор им не нужен.
            stream.startCapture { @Sendable error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        return CaptureProcess(
            interrupt: { stream.stopCapture { @Sendable _ in end.finishSoon() } },
            finished: {
                for await _ in end.finished {}
                // Системная кнопка «стоп» закрывает только файл — поток останавливаем сами.
                withExtendedLifetime(recordingOutput) {}
                stream.stopCapture { @Sendable _ in }
            },
            // Не дольше 5 с: зависшая запись не должна держать выход из приложения.
            waitUntilExit: { end.wait(seconds: 5) }
        )
    }
}

/// Конец записи. SCK зовёт делегатов со своей очереди, а главный поток при выходе
/// из приложения стоит в wait — поэтому здесь ничего от главного актора.
nonisolated private final class RecordingEnd: NSObject, SCStreamDelegate, SCRecordingOutputDelegate, Sendable {
    let finished: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation
    private let closed = DispatchSemaphore(value: 0)

    override init() {
        (finished, signal) = AsyncStream<Void>.makeStream()
    }

    func wait(seconds: TimeInterval) {
        _ = closed.wait(timeout: .now() + seconds)
    }

    /// Поток остановлен; если делегат записи так и не сообщит о закрытии файла — не ждать вечно.
    func finishSoon() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { self.finish() }
    }

    private func finish() {
        signal.finish()
        closed.signal()
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) { finish() }
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) { finish() }
    func stream(_ stream: SCStream, didStopWithError error: any Error) { finishSoon() }
}

extension ToolsStore.Environment {
    /// Что писать; nil — выбор отменён.
    func source(for kind: ToolsStore.RecordingKind) async -> RecordingSource? {
        switch kind {
        case .display: .display
        case .area: await pickArea().map { RecordingSource.area($0) }
        case .window: await pickWindow().map { RecordingSource.window($0) }
        }
    }

    /// Звук для новой записи; nil — микрофон выбран, но доступа к нему нет.
    func audio(for wanted: RecordingAudio) async -> RecordingAudio? {
        var audio = wanted
        guard audio.microphone != .none else { return audio }
        switch microphoneStatus() {
        case .authorized: break
        case .notDetermined: guard await requestMicrophone() else { return nil }
        default: return nil
        }
        // Выбранное устройство отключили — пишем с микрофона по умолчанию.
        if case .device(let id) = audio.microphone, !microphones().contains(where: { $0.id == id }) {
            audio.microphone = .systemDefault
        }
        return audio
    }
}
