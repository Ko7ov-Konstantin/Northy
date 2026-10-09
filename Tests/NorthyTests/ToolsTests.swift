import AppKit
import AVFoundation
import Foundation
import IOKit.pwr_mgt
import Testing
@testable import Northy

@MainActor
/// «Инструменты»: аргументы screencapture, имена файлов и автомат состояний —
/// без обращения к экрану, запуск процесса и разрешение подменены.
struct ToolsTests {

    /// Подмена screencapture и рекордера: снимок «завершается» сразу, запись — по interrupt.
    @MainActor private final class FakeCapture {
        var launches: [[String]] = []
        var recordings: [RecordingAudio] = []
        var sources: [RecordingSource] = []
        var interrupts = 0
        /// false — пользователь нажал Esc: файла нет.
        var createsFile = true
        var failsRecording = false

        func launch(_ arguments: [String]) -> CaptureProcess {
            launches.append(arguments)
            return process(output: URL(fileURLWithPath: arguments.last ?? ""), finishesAtOnce: true)
        }

        func record(_ audio: RecordingAudio, _ source: RecordingSource, to output: URL) throws -> CaptureProcess {
            if failsRecording { throw CocoaError(.featureUnsupported) }
            launches.append([output.path])
            recordings.append(audio)
            sources.append(source)
            return process(output: output, finishesAtOnce: false)
        }

        private func process(output: URL, finishesAtOnce: Bool) -> CaptureProcess {
            let (exited, signal) = AsyncStream<Void>.makeStream()
            let finish = { [self] in
                if createsFile { try? Data([1, 2, 3]).write(to: output) }
                signal.finish()
            }
            if finishesAtOnce { finish() }
            return CaptureProcess(
                interrupt: { [self] in
                    interrupts += 1
                    finish()
                },
                finished: { for await _ in exited {} },
                waitUntilExit: {}
            )
        }
    }

    /// Подмена сведения звука: помнит файлы и полку на момент вызова.
    @MainActor private final class FakeMix {
        var files: [URL] = []
        var shelfCounts: [Int] = []
        var fails = false
        /// Пока задан — сведение «висит» до resume.
        var hold: CheckedContinuation<Void, Never>?
        var holds = false
    }

    @MainActor private final class FakeMicrophone {
        var status = AVAuthorizationStatus.authorized
        var grantsOnRequest = true
        var statusChecks = 0
        var requests = 0
        var devices: [AudioInput] = []
    }

    @MainActor private final class Copied {
        var images: [URL] = []
        var texts: [String] = []
    }

    /// Подмена пипетки, выбора области и запрета сна.
    @MainActor private final class FakePicker {
        var color: NSColor?
        var picks = 0
        /// Пока задан — выбор «висит» до вызова release.
        var hold: CheckedContinuation<Void, Never>?
        var holdPicks = false
        var area: CGRect?
        var areaPicks = 0
        /// Пока задан — выбор области «висит» до resume.
        var areaHold: CheckedContinuation<Void, Never>?
        var holdAreaPicks = false
        var window: CGWindowID?
        var windowPicks = 0
        /// Пока задан — выбор окна «висит» до resume.
        var windowHold: CheckedContinuation<Void, Never>?
        var holdWindowPicks = false
        /// false — отсчёт перед записью отменён (Esc).
        var countdownPasses = true
        var countdowns = 0
        /// Что уже случилось к началу отсчёта.
        var atCountdown: (() -> Void)?
        var countdownHold: CheckedContinuation<Void, Never>?
        var holdCountdown = false
    }

    @MainActor private final class FakeSleep {
        var created: [String] = []
        var released: [IOPMAssertionID] = []
        var failCreate = false
    }

    private struct Fixture {
        let store: ToolsStore
        let shelf: ShelfStore
        let capture: FakeCapture
        let mix: FakeMix
        let microphone: FakeMicrophone
        let copied: Copied
        let picker: FakePicker
        let sleep: FakeSleep
        let drops: URL
        let temp: URL
    }

    private func makeFixture(permission: Bool = true, recognized: Result<String, TextRecognition.Failure> = .success("привет"), audio: RecordingAudio = RecordingAudio()) -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NorthyTests-\(UUID().uuidString)", isDirectory: true)
        let drops = root.appendingPathComponent("Drops", isDirectory: true)
        let temp = root.appendingPathComponent("tmp", isDirectory: true)
        for dir in [drops, temp] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let shelf = ShelfStore(directory: root, dropsDirectory: drops)
        let capture = FakeCapture()
        let mix = FakeMix()
        let microphone = FakeMicrophone()
        let copied = Copied()
        let picker = FakePicker()
        let sleep = FakeSleep()
        let environment = ToolsStore.Environment(
            hasPermission: { permission },
            requestPermission: {},
            launch: { capture.launch($0) },
            record: { try capture.record($0, $1, to: $2) },
            mixAudio: { file in
                mix.files.append(file)
                mix.shelfCounts.append(shelf.files.count)
                if mix.holds { await withCheckedContinuation { mix.hold = $0 } }
                if mix.fails { throw CocoaError(.fileWriteUnknown) }
            },
            microphoneStatus: {
                microphone.statusChecks += 1
                return microphone.status
            },
            requestMicrophone: {
                microphone.requests += 1
                return microphone.grantsOnRequest
            },
            microphones: { microphone.devices },
            recognize: { _ in try recognized.get() },
            copyImage: { copied.images.append($0) },
            copyText: { copied.texts.append($0) },
            pickColor: {
                picker.picks += 1
                if picker.holdPicks { await withCheckedContinuation { picker.hold = $0 } }
                return picker.color
            },
            pickArea: {
                picker.areaPicks += 1
                if picker.holdAreaPicks { await withCheckedContinuation { picker.areaHold = $0 } }
                return picker.area
            },
            pickWindow: {
                picker.windowPicks += 1
                if picker.holdWindowPicks { await withCheckedContinuation { picker.windowHold = $0 } }
                return picker.window
            },
            countdown: {
                picker.countdowns += 1
                picker.atCountdown?()
                if picker.holdCountdown { await withCheckedContinuation { picker.countdownHold = $0 } }
                return picker.countdownPasses
            },
            createSleepAssertion: { reason in
                sleep.created.append(reason)
                return sleep.failCreate ? nil : IOPMAssertionID(100 + sleep.created.count)
            },
            releaseSleepAssertion: { sleep.released.append($0) },
            temporaryDirectory: temp,
            dropsDirectory: drops
        )
        // Один набор на все фикстуры: стор читает звук из памяти, а прогоны не копят plist-файлы.
        let settings = AppSettings(defaults: UserDefaults(suiteName: "NorthyTests-tools")!)
        settings.recordingAudio = audio
        return Fixture(store: ToolsStore(shelf: shelf, settings: settings, environment: environment), shelf: shelf, capture: capture, mix: mix, microphone: microphone, copied: copied, picker: picker, sleep: sleep, drops: drops, temp: temp)
    }

    private func leftovers(in directory: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    }

    // MARK: аргументы и имена

    @Test func argumentsForEveryMode() {
        let png = URL(fileURLWithPath: "/tmp/x.png")
        #expect(ScreenCapture.arguments(for: .area, output: png) == ["-i", "-s", "/tmp/x.png"])
        #expect(ScreenCapture.arguments(for: .window, output: png) == ["-i", "-w", "/tmp/x.png"])
        #expect(ScreenCapture.arguments(for: .screen, output: png) == ["-m", "/tmp/x.png"])
        #expect(ScreenCapture.arguments(for: .text, output: png) == ["-i", "-s", "-x", "/tmp/x.png"])
        #expect(ScreenCapture.executable.path == "/usr/sbin/screencapture")
    }

    @Test func fileNameCarriesDateAndExtension() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let date = Date(timeIntervalSince1970: 1_791_417_845) // 2026-10-08 00:04:05 UTC
        #expect(ScreenCapture.fileName(for: .area, date: date, timeZone: utc) == "Снимок 2026-10-08 в 00.04.05.png")
        #expect(ScreenCapture.fileName(for: .screen, date: date, timeZone: utc) == "Снимок 2026-10-08 в 00.04.05.png")
        #expect(ScreenCapture.fileName(for: .recording, date: date, timeZone: utc) == "Запись 2026-10-08 в 00.04.05.mov")
    }

    // MARK: снимки

    @Test func screenshotLandsOnShelfAndInClipboard() async throws {
        let fixture = makeFixture()
        var hidden = 0, shown = 0
        fixture.store.hidePanel = { hidden += 1 }
        fixture.store.onShelfAdded = { shown += 1 }

        await fixture.store.capture(.area)

        let file = try #require(fixture.shelf.files.first)
        #expect(fixture.shelf.files.count == 1)
        #expect(file.lastPathComponent.hasPrefix("Снимок "))
        #expect(file.pathExtension == "png")
        #expect(file.path.hasPrefix(fixture.drops.path + "/"), "в папке полки — её очистка удалит файл")
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(fixture.copied.images == [file])
        #expect(leftovers(in: fixture.temp).isEmpty, "временный файл перенесён")
        #expect(hidden == 1 && shown == 1)
        #expect(fixture.store.activity == .idle)

        fixture.shelf.clear()
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func cancelledSelectionAddsNothing() async {
        let fixture = makeFixture()
        fixture.capture.createsFile = false
        var shown = 0
        fixture.store.onShelfAdded = { shown += 1 }

        await fixture.store.capture(.window)

        #expect(fixture.capture.launches.count == 1)
        #expect(fixture.shelf.files.isEmpty)
        #expect(fixture.copied.images.isEmpty)
        #expect(fixture.store.status == nil, "отмена — не ошибка")
        #expect(shown == 0)
        #expect(fixture.store.activity == .idle)
    }

    @Test func textGoesToClipboardAndFileIsRemoved() async {
        let fixture = makeFixture()
        var shown = 0
        fixture.store.onShelfAdded = { shown += 1 }

        await fixture.store.capture(.text)

        #expect(fixture.copied.texts == ["привет"])
        #expect(fixture.shelf.files.isEmpty)
        #expect(leftovers(in: fixture.temp).isEmpty)
        #expect(shown == 0, "после распознавания панель не разворачивается")
    }

    @Test func emptyRecognitionShowsMessage() async {
        let fixture = makeFixture(recognized: .failure(.noText))
        await fixture.store.capture(.text)
        #expect(fixture.copied.texts.isEmpty)
        #expect(fixture.store.status == "Текст не найден")
        #expect(leftovers(in: fixture.temp).isEmpty)
    }

    // MARK: разрешение

    @Test func withoutPermissionNothingStarts() async {
        let fixture = makeFixture(permission: false)
        var hidden = 0
        fixture.store.hidePanel = { hidden += 1 }

        await fixture.store.capture(.screen)
        await fixture.store.startRecording()

        #expect(fixture.capture.launches.isEmpty)
        #expect(fixture.store.needsPermission)
        #expect(fixture.store.activity == .idle)
        #expect(hidden == 0)
    }

    // MARK: запись

    @Test func recordingStateMachine() async throws {
        let fixture = makeFixture()
        var shown = 0
        fixture.store.onShelfAdded = { shown += 1 }
        #expect(fixture.store.activity == .idle)

        await fixture.store.startRecording()
        #expect(fixture.store.isRecording)
        await fixture.store.startRecording()
        await fixture.store.capture(.area)
        #expect(fixture.capture.launches.count == 1, "во время записи ничего больше не запускается")
        #expect(fixture.shelf.files.isEmpty)

        fixture.store.stopRecording()
        #expect(fixture.store.activity == .finishing)
        fixture.store.stopRecording()
        #expect(fixture.capture.interrupts == 1)
        await fixture.store.recordingTask?.value

        #expect(fixture.store.activity == .idle)
        let file = try #require(fixture.shelf.files.first)
        #expect(file.lastPathComponent.hasPrefix("Запись "))
        #expect(file.pathExtension == "mov")
        #expect(file.path.hasPrefix(fixture.drops.path + "/"))
        #expect(shown == 1)
        #expect(fixture.copied.images.isEmpty, "видео в буфер не кладётся")
    }

    @Test func quittingDuringRecordingSavesTheFile() async {
        let fixture = makeFixture()
        var shown = 0
        fixture.store.onShelfAdded = { shown += 1 }
        await fixture.store.startRecording()

        fixture.store.finishForTermination()

        #expect(fixture.capture.interrupts == 1)
        #expect(fixture.shelf.files.count == 1)
        #expect(shown == 0, "при выходе панель не показывается")
        #expect(fixture.store.activity == .idle)
    }

    // MARK: сведение звука

    @Test func stoppingMixesAudioBeforeShelf() async throws {
        let fixture = makeFixture()
        fixture.mix.holds = true
        await fixture.store.startRecording()
        let recorded = URL(fileURLWithPath: try #require(fixture.capture.launches.first?.first))

        fixture.store.stopRecording()
        while fixture.mix.hold == nil { await Task.yield() }

        #expect(fixture.store.activity == .finishing, "пока звук сводится, плитка показывает «Сохраняю запись…»")
        #expect(fixture.shelf.files.isEmpty)
        #expect(FileManager.default.fileExists(atPath: recorded.path), "сводится готовый файл записи")

        fixture.mix.hold?.resume()
        await fixture.store.recordingTask?.value

        #expect(fixture.mix.files == [recorded])
        #expect(fixture.mix.shelfCounts == [0], "сведение — до полки")
        #expect(fixture.shelf.files.count == 1)
        #expect(fixture.store.activity == .idle)
    }

    @Test func failedMixStillSavesRecording() async {
        let fixture = makeFixture()
        fixture.mix.fails = true
        await fixture.store.startRecording()

        fixture.store.stopRecording()
        await fixture.store.recordingTask?.value

        #expect(fixture.mix.files.count == 1)
        #expect(fixture.shelf.files.count == 1)
        #expect(fixture.store.activity == .idle)
        #expect(fixture.store.status == "Запись на полке")
    }

    @Test func quittingDuringRecordingSkipsMix() async {
        let fixture = makeFixture()
        await fixture.store.startRecording()

        fixture.store.finishForTermination()
        await fixture.store.recordingTask?.value

        #expect(fixture.mix.files.isEmpty)
        #expect(fixture.shelf.files.count == 1)
    }

    @Test func quittingDuringMixSavesRecordingOnce() async {
        let fixture = makeFixture()
        fixture.mix.holds = true
        var shown = 0
        fixture.store.onShelfAdded = { shown += 1 }
        await fixture.store.startRecording()
        fixture.store.stopRecording()
        while fixture.mix.hold == nil { await Task.yield() }

        fixture.store.finishForTermination()
        #expect(fixture.shelf.files.count == 1)
        #expect(fixture.capture.interrupts == 1)

        fixture.mix.hold?.resume()
        await fixture.store.recordingTask?.value
        #expect(fixture.shelf.files.count == 1, "запись не завершается дважды")
        #expect(shown == 0)
        #expect(fixture.store.activity == .idle)
    }

    // MARK: звук записи

    @Test func silentRecordingNeverTouchesMicrophone() async {
        let fixture = makeFixture(audio: RecordingAudio(systemSound: false, microphone: .none))

        await fixture.store.startRecording()

        #expect(fixture.capture.recordings == [RecordingAudio(systemSound: false, microphone: .none)])
        #expect(fixture.microphone.statusChecks == 0)
        #expect(fixture.microphone.requests == 0)
        fixture.store.finishForTermination()
    }

    @Test func systemSoundReachesRecorder() async {
        let fixture = makeFixture(audio: RecordingAudio(systemSound: true, microphone: .none))
        await fixture.store.startRecording()
        #expect(fixture.capture.recordings.first?.systemSound == true)
        #expect(fixture.capture.recordings.first?.microphone == RecordingAudio.Microphone.none)
        fixture.store.finishForTermination()
    }

    @Test func defaultMicrophoneReachesRecorder() async {
        let fixture = makeFixture(audio: RecordingAudio(systemSound: false, microphone: .systemDefault))
        await fixture.store.startRecording()
        #expect(fixture.capture.recordings == [RecordingAudio(systemSound: false, microphone: .systemDefault)])
        #expect(fixture.microphone.requests == 0, "доступ уже есть — не спрашиваем")
        fixture.store.finishForTermination()
    }

    @Test func connectedMicrophoneIsUsedById() async {
        let fixture = makeFixture(audio: RecordingAudio(systemSound: true, microphone: .device("usb-1")))
        fixture.microphone.devices = [AudioInput(id: "built-in", name: "MacBook"), AudioInput(id: "usb-1", name: "USB")]
        await fixture.store.startRecording()
        #expect(fixture.capture.recordings == [RecordingAudio(systemSound: true, microphone: .device("usb-1"))])
        fixture.store.finishForTermination()
    }

    @Test func unpluggedMicrophoneFallsBackToDefault() async {
        let fixture = makeFixture(audio: RecordingAudio(systemSound: true, microphone: .device("usb-1")))
        fixture.microphone.devices = [AudioInput(id: "built-in", name: "MacBook")]
        await fixture.store.startRecording()
        #expect(fixture.capture.recordings == [RecordingAudio(systemSound: true, microphone: .systemDefault)])
        fixture.store.finishForTermination()
    }

    @Test func microphoneAccessIsAskedOnce() async {
        let fixture = makeFixture(audio: RecordingAudio(systemSound: false, microphone: .systemDefault))
        fixture.microphone.status = .notDetermined

        await fixture.store.startRecording()

        #expect(fixture.microphone.requests == 1)
        #expect(fixture.store.isRecording)
        #expect(fixture.capture.recordings.first?.microphone == .systemDefault)
        fixture.store.finishForTermination()
    }

    @Test(arguments: [AVAuthorizationStatus.denied, .restricted, .notDetermined])
    func withoutMicrophoneAccessRecordingDoesNotStart(status: AVAuthorizationStatus) async {
        let fixture = makeFixture(audio: RecordingAudio(systemSound: true, microphone: .systemDefault))
        fixture.microphone.status = status
        fixture.microphone.grantsOnRequest = false
        var hidden = 0
        fixture.store.hidePanel = { hidden += 1 }

        await fixture.store.startRecording()

        #expect(fixture.capture.launches.isEmpty)
        #expect(fixture.store.activity == .idle)
        #expect(fixture.store.status == "Нет доступа к микрофону — включите его в настройках")
        #expect(hidden == 0, "отказ — до того, как панель спрячется")
        #expect(fixture.shelf.files.isEmpty)
        #expect(fixture.microphone.requests == (status == .notDetermined ? 1 : 0))
    }

    @Test func failedRecorderLeavesStoreIdle() async {
        let fixture = makeFixture()
        fixture.capture.failsRecording = true

        await fixture.store.startRecording()

        #expect(fixture.store.activity == .idle)
        #expect(fixture.store.status == "Не удалось начать запись")
        #expect(fixture.shelf.files.isEmpty)
        #expect(leftovers(in: fixture.temp).isEmpty)
    }

    // MARK: запись области

    @Test func fullScreenRecordingPassesDisplaySource() async {
        let fixture = makeFixture()

        await fixture.store.startRecording()

        #expect(fixture.capture.sources == [.display])
        #expect(fixture.picker.areaPicks == 0)
        fixture.store.finishForTermination()
    }

    @Test func windowRecordingPassesSelectedWindow() async {
        let fixture = makeFixture()
        fixture.picker.window = 42

        await fixture.store.startRecording(.window)

        #expect(fixture.capture.sources == [.window(42)])
        #expect(fixture.store.isRecording)
        fixture.store.finishForTermination()
    }

    @Test func cancelledWindowLeavesNothingBehind() async {
        let fixture = makeFixture()
        fixture.picker.window = nil

        await fixture.store.startRecording(.window)

        #expect(fixture.capture.launches.isEmpty)
        #expect(fixture.store.activity == .idle)
        #expect(fixture.store.status == nil)
        #expect(fixture.shelf.files.isEmpty)
    }

    @Test func panelHidesBeforeWindowIsPicked() async {
        let fixture = makeFixture()
        var hidden = 0
        fixture.store.hidePanel = { hidden += 1 }
        fixture.picker.window = 7
        fixture.picker.holdWindowPicks = true

        let recording = Task { await fixture.store.startRecording(.window) }
        while fixture.picker.windowHold == nil { await Task.yield() }
        #expect(hidden == 1, "панель уходит из кадра до выбора окна")

        fixture.picker.windowHold?.resume()
        await recording.value
        fixture.store.finishForTermination()
    }

    @Test func pickersAreCalledOnlyForTheirKind() async {
        let fixture = makeFixture()
        fixture.picker.area = CGRect(x: 0, y: 0, width: 100, height: 100)

        await fixture.store.startRecording()
        #expect(fixture.capture.sources == [.display])
        #expect(fixture.picker.areaPicks == 0)
        #expect(fixture.picker.windowPicks == 0)
        fixture.store.stopRecording()
        await fixture.store.recordingTask?.value

        await fixture.store.startRecording(.area)
        #expect(fixture.picker.windowPicks == 0)
        fixture.store.finishForTermination()
    }

    @Test func areaRecordingPassesSelectedRect() async {
        let fixture = makeFixture()
        let rect = CGRect(x: 10, y: 20, width: 300, height: 200)
        fixture.picker.area = rect

        await fixture.store.startRecording(.area)

        #expect(fixture.capture.sources == [.area(rect)])
        #expect(fixture.store.isRecording)
        fixture.store.finishForTermination()
    }

    @Test func cancelledAreaLeavesNothingBehind() async {
        let fixture = makeFixture()
        fixture.picker.area = nil

        await fixture.store.startRecording(.area)

        #expect(fixture.capture.launches.isEmpty)
        #expect(fixture.store.activity == .idle)
        #expect(fixture.store.status == nil)
        #expect(fixture.shelf.files.isEmpty)
    }

    @Test func panelHidesBeforeAreaIsPicked() async {
        let fixture = makeFixture()
        var hidden = 0
        fixture.store.hidePanel = { hidden += 1 }
        fixture.picker.area = CGRect(x: 0, y: 0, width: 100, height: 100)
        fixture.picker.holdAreaPicks = true

        let recording = Task { await fixture.store.startRecording(.area) }
        while fixture.picker.areaHold == nil { await Task.yield() }
        #expect(hidden == 1, "панель уходит из кадра до выделения")

        fixture.picker.areaHold?.resume()
        await recording.value
        fixture.store.finishForTermination()
    }

    @Test func nothingStartsWhileAreaIsPicked() async {
        let fixture = makeFixture()
        fixture.picker.area = CGRect(x: 0, y: 0, width: 100, height: 100)
        fixture.picker.holdAreaPicks = true

        let picking = Task { await fixture.store.startRecording(.area) }
        while fixture.picker.areaHold == nil { await Task.yield() }
        #expect(fixture.store.activity == .capturing(.recording))

        await fixture.store.startRecording()
        await fixture.store.startRecording(.area)
        await fixture.store.capture(.area)
        #expect(fixture.capture.launches.isEmpty)
        #expect(fixture.picker.areaPicks == 1)

        fixture.picker.areaHold?.resume()
        await picking.value
        fixture.store.finishForTermination()
    }

    @Test func areaRecordingIsSavedLikeFullScreen() async throws {
        let fixture = makeFixture()
        fixture.picker.area = CGRect(x: 10, y: 20, width: 300, height: 200)
        var shown = 0
        fixture.store.onShelfAdded = { shown += 1 }

        await fixture.store.startRecording(.area)
        fixture.store.stopRecording()
        await fixture.store.recordingTask?.value

        #expect(fixture.store.activity == .idle)
        let file = try #require(fixture.shelf.files.first)
        #expect(file.lastPathComponent.hasPrefix("Запись "))
        #expect(file.pathExtension == "mov")
        #expect(fixture.mix.files.count == 1, "звук сводится так же")
        #expect(shown == 1)
    }

    // MARK: пипетка

    @Test func hexBlackWhiteAndRounding() {
        #expect(ColorHex.string(red: 0, green: 0, blue: 0) == "#000000")
        #expect(ColorHex.string(red: 1, green: 1, blue: 1) == "#FFFFFF")
        #expect(ColorHex.string(red: 0.5, green: 0.2, blue: 1) == "#8033FF", "0.5 -> 127.5 -> 128 = 80")
        #expect(ColorHex.string(red: 0.999, green: 0.001, blue: 0.0019) == "#FF0000")
    }

    @Test func hexClampsOutOfRange() {
        #expect(ColorHex.string(red: -0.3, green: 1.7, blue: 2) == "#00FFFF")
    }

    @Test func pickedColorGoesToClipboard() async throws {
        let fixture = makeFixture(permission: false)
        fixture.picker.color = NSColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 0.4)
        var hidden = 0
        fixture.store.hidePanel = { hidden += 1 }

        await fixture.store.pickColor()

        #expect(fixture.copied.texts == ["#FF8000"])
        #expect(fixture.store.status == "Цвет #FF8000 скопирован")
        #expect(hidden == 1)
        #expect(!fixture.store.needsPermission, "пипетке разрешение не нужно")
        #expect(fixture.store.activity == .idle)
    }

    @Test func cancelledPickerLeavesClipboardAlone() async {
        let fixture = makeFixture()
        fixture.picker.color = nil

        await fixture.store.pickColor()

        #expect(fixture.picker.picks == 1)
        #expect(fixture.copied.texts.isEmpty)
        #expect(fixture.store.status == nil)
        #expect(fixture.store.activity == .idle)
    }

    @Test func nothingStartsWhilePicking() async {
        let fixture = makeFixture()
        fixture.picker.holdPicks = true
        fixture.picker.color = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)

        let picking = Task { await fixture.store.pickColor() }
        while fixture.picker.hold == nil { await Task.yield() }
        #expect(fixture.store.activity == .pickingColor)

        await fixture.store.capture(.area)
        await fixture.store.startRecording()
        await fixture.store.pickColor()
        #expect(fixture.capture.launches.isEmpty)
        #expect(fixture.picker.picks == 1)

        fixture.picker.hold?.resume()
        await picking.value
        #expect(fixture.store.activity == .idle)
    }

    // MARK: не давать уснуть

    @Test func keepAwakeTogglesAssertion() {
        let fixture = makeFixture()
        #expect(!fixture.store.isKeepingAwake)

        fixture.store.setKeepAwake(true)
        fixture.store.setKeepAwake(true)
        #expect(fixture.store.isKeepingAwake)
        #expect(fixture.sleep.created == ["Northy: не давать уснуть"])

        fixture.store.setKeepAwake(false)
        #expect(!fixture.store.isKeepingAwake)
        #expect(fixture.sleep.released == [101])
        fixture.store.setKeepAwake(false)
        #expect(fixture.sleep.released == [101], "повторное выключение ничего не отпускает")
    }

    @Test func quittingReleasesKeepAwake() {
        let fixture = makeFixture()
        fixture.store.setKeepAwake(true)

        fixture.store.finishForTermination()

        #expect(fixture.sleep.released == [101])
        #expect(!fixture.store.isKeepingAwake)
    }

    @Test func failedKeepAwakeStaysOff() {
        let fixture = makeFixture()
        fixture.sleep.failCreate = true

        fixture.store.setKeepAwake(true)

        #expect(!fixture.store.isKeepingAwake)
        #expect(fixture.store.status == "Не удалось включить запрет сна")
        #expect(fixture.sleep.released.isEmpty)
    }

    @Test func keepAwakeWorksDuringRecording() async {
        let fixture = makeFixture()
        await fixture.store.startRecording()

        fixture.store.setKeepAwake(true)

        #expect(fixture.store.isKeepingAwake)
        #expect(fixture.store.isRecording)
        fixture.store.finishForTermination()
        #expect(fixture.sleep.released == [101], "и запись, и запрет сна завершаются при выходе")
    }

    // MARK: вкладка

    @Test func toolsTabIsLast() {
        #expect(PanelTab.allCases.last == .tools)
        #expect(PanelTab.tools.title == "Инструменты")
    }

    @Test func toolsTabTurnsOnOnceForExistingUsers() throws {
        let suite = "NorthyTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { discardDefaults(defaults, suite: suite) }
        defaults.set(["clipboard", "files"], forKey: "panel.enabledTabs")

        #expect(AppSettings(defaults: defaults).enabledTabs == [.clipboard, .files, .tools])
        #expect(AppSettings(defaults: defaults).enabledTabs == [.clipboard, .files, .tools], "включение сохранено")

        let settings = AppSettings(defaults: defaults)
        settings.enabledTabs.remove(.tools)
        #expect(AppSettings(defaults: defaults).enabledTabs == [.clipboard, .files], "выключенная не возвращается")
    }

    @Test func toolsTabStaysOffOnFirstLaunch() throws {
        let suite = "NorthyTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { discardDefaults(defaults, suite: suite) }

        let settings = AppSettings(defaults: defaults)
        #expect(settings.enabledTabs == [.clipboard], "новый пользователь включает вкладки сам")
        settings.enabledTabs.insert(.files)
        #expect(AppSettings(defaults: defaults).enabledTabs == [.clipboard, .files])
    }

    // MARK: отсчёт перед записью

    @Test func recordingStartsAfterCountdown() async {
        let fixture = makeFixture()
        var launchesAtCountdown = -1
        fixture.picker.atCountdown = { launchesAtCountdown = fixture.capture.launches.count }

        await fixture.store.startRecording()

        #expect(fixture.picker.countdowns == 1)
        #expect(launchesAtCountdown == 0, "во время отсчёта запись ещё не идёт")
        #expect(fixture.store.isRecording)
        fixture.store.finishForTermination()
    }

    @Test func cancelledCountdownStartsNothing() async {
        let fixture = makeFixture()
        fixture.picker.countdownPasses = false

        await fixture.store.startRecording()

        #expect(fixture.capture.launches.isEmpty)
        #expect(fixture.store.activity == .idle)
        #expect(fixture.store.status == nil)
        #expect(fixture.shelf.files.isEmpty)
    }

    @Test func countdownComesAfterAreaIsPicked() async {
        let fixture = makeFixture()
        fixture.picker.area = CGRect(x: 10, y: 20, width: 300, height: 200)
        var picksAtCountdown = -1
        fixture.picker.atCountdown = { picksAtCountdown = fixture.picker.areaPicks }

        await fixture.store.startRecording(.area)

        #expect(picksAtCountdown == 1)
        #expect(fixture.picker.countdowns == 1)
        fixture.store.finishForTermination()
    }

    @Test func cancelledAreaSkipsCountdown() async {
        let fixture = makeFixture()
        fixture.picker.area = nil

        await fixture.store.startRecording(.area)

        #expect(fixture.picker.countdowns == 0)
    }

    @Test func nothingStartsDuringCountdown() async throws {
        let fixture = makeFixture()
        fixture.picker.holdCountdown = true
        let first = Task { await fixture.store.startRecording() }
        while fixture.picker.countdownHold == nil { await Task.yield() }

        #expect(fixture.store.activity == .capturing(.recording))
        #expect(!fixture.store.isRecording)
        await fixture.store.startRecording()
        #expect(fixture.picker.countdowns == 1)
        #expect(fixture.capture.launches.isEmpty)

        fixture.picker.countdownHold?.resume()
        await first.value
        #expect(fixture.store.isRecording)
        fixture.store.finishForTermination()
    }
}
