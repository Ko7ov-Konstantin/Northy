import Foundation
import Testing
@testable import Northy

@MainActor
/// Плитка «Скрипт»: запуск и остановка процесса — процесс, выбор файла и разрешение подменены.
struct ScriptRunnerTests {

    @MainActor private final class FakeScript {
        var launched: [URL] = []
        var interrupts = 0
        var trusted = true
        var trustRequests = 0
        var picks = 0
        var picked: URL?
        var fileExists = true
        var failsLaunch = false
        private var exits: AsyncStream<Int32>.Continuation?

        func launch(_ url: URL) throws -> ScriptProcess {
            if failsLaunch { throw CocoaError(.fileNoSuchFile) }
            launched.append(url)
            let (stream, continuation) = AsyncStream<Int32>.makeStream()
            exits = continuation
            return ScriptProcess(
                interrupt: { [self] in interrupts += 1 },
                finished: {
                    for await code in stream { return code }
                    return 0
                }
            )
        }

        func exit(_ code: Int32) {
            exits?.yield(code)
            exits?.finish()
        }
    }

    private struct Fixture {
        let runner: ScriptRunner
        let fake: FakeScript
        let settings: AppSettings
    }

    private func makeFixture(savedPath: String? = nil) -> Fixture {
        let fake = FakeScript()
        let settings = AppSettings(defaults: UserDefaults(suiteName: "NorthyTests-script")!)
        settings.scriptPath = savedPath
        let runner = ScriptRunner(settings: settings, environment: ScriptRunner.Environment(
            launch: { try fake.launch($0) },
            isTrusted: { fake.trusted },
            requestTrust: { fake.trustRequests += 1 },
            pickFile: {
                fake.picks += 1
                return fake.picked
            },
            fileExists: { _ in fake.fileExists }
        ))
        return Fixture(runner: runner, fake: fake, settings: settings)
    }

    private func waitUntilStopped(_ runner: ScriptRunner) async {
        var spins = 0
        while runner.isRunning, spins < 10_000 {
            await Task.yield()
            spins += 1
        }
    }

    private let sample = URL(fileURLWithPath: "/tmp/sample-script.py")

    // MARK: выбор файла

    @Test func cancelledPickStartsNothing() async {
        let f = makeFixture()
        await f.runner.toggle()
        #expect(f.fake.picks == 1)
        #expect(f.fake.launched.isEmpty)
        #expect(!f.runner.isRunning)
        #expect(f.settings.scriptPath == nil)
    }

    @Test func pickedFileIsSavedAndLaunched() async {
        let f = makeFixture()
        f.fake.picked = sample
        await f.runner.toggle()
        #expect(f.settings.scriptPath == sample.path)
        #expect(f.fake.launched == [sample])
        #expect(f.runner.isRunning)
    }

    @Test func savedFileIsLaunchedWithoutPicker() async {
        let f = makeFixture(savedPath: sample.path)
        await f.runner.toggle()
        #expect(f.fake.picks == 0)
        #expect(f.fake.launched == [sample])
    }

    @Test func missingSavedFileAsksAgain() async {
        let f = makeFixture(savedPath: sample.path)
        f.fake.fileExists = false
        await f.runner.toggle()
        #expect(f.fake.picks == 1)
        #expect(f.fake.launched.isEmpty)
    }

    // MARK: остановка

    @Test func secondPressInterruptsOnceAndExitTurnsOff() async {
        let f = makeFixture(savedPath: sample.path)
        await f.runner.toggle()
        await f.runner.toggle()
        #expect(f.fake.interrupts == 1)
        #expect(f.runner.isRunning, "выключается, когда процесс реально завершился")

        f.fake.exit(130)
        await waitUntilStopped(f.runner)
        #expect(!f.runner.isRunning)
        #expect(f.runner.status == nil)
    }

    @Test func pressWhileStoppingDoesNothing() async {
        let f = makeFixture(savedPath: sample.path)
        await f.runner.toggle()
        await f.runner.toggle()
        await f.runner.toggle()
        #expect(f.fake.launched.count == 1)
        #expect(f.fake.interrupts == 1)
        #expect(f.runner.isRunning)
    }

    // MARK: самостоятельное завершение

    @Test func selfExitWithZeroIsQuiet() async {
        let f = makeFixture(savedPath: sample.path)
        await f.runner.toggle()
        f.fake.exit(0)
        await waitUntilStopped(f.runner)
        #expect(!f.runner.isRunning)
        #expect(f.fake.interrupts == 0)
        #expect(f.runner.status == nil)
    }

    @Test func selfExitWithErrorShowsStatus() async {
        let f = makeFixture(savedPath: sample.path)
        await f.runner.toggle()
        f.fake.exit(1)
        await waitUntilStopped(f.runner)
        #expect(!f.runner.isRunning)
        #expect(f.runner.status == "Скрипт завершился с ошибкой")
    }

    // MARK: отказы

    @Test func missingAccessibilityBlocksLaunch() async {
        let f = makeFixture(savedPath: sample.path)
        f.fake.trusted = false
        await f.runner.toggle()
        #expect(f.fake.launched.isEmpty)
        #expect(f.fake.trustRequests == 1)
        #expect(f.runner.status == "Нужно разрешение „Универсальный доступ“ — без него нажатия не дойдут")
        #expect(!f.runner.isRunning)
    }

    @Test func launchFailureShowsStatus() async {
        let f = makeFixture(savedPath: sample.path)
        f.fake.failsLaunch = true
        await f.runner.toggle()
        #expect(!f.runner.isRunning)
        #expect(f.runner.status == "Не удалось запустить скрипт")
    }

    // MARK: связь со стором

    private func makeStore(script: ScriptRunner, settings: AppSettings) -> ToolsStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NorthyTests-\(UUID().uuidString)", isDirectory: true)
        let shelf = ShelfStore(directory: root, dropsDirectory: root.appendingPathComponent("Drops", isDirectory: true))
        let environment = ToolsStore.Environment(
            hasPermission: { true },
            record: { _, _, _ in
                CaptureProcess(interrupt: {}, finished: { try? await Task.sleep(for: .seconds(60)) }, waitUntilExit: {})
            },
            temporaryDirectory: root
        )
        return ToolsStore(shelf: shelf, settings: settings, environment: environment, script: script)
    }

    @Test func terminationInterruptsRunningScript() async {
        let f = makeFixture(savedPath: sample.path)
        let store = makeStore(script: f.runner, settings: f.settings)
        await f.runner.toggle()
        store.finishForTermination()
        #expect(f.fake.interrupts == 1)
    }

    @Test func terminationWithoutScriptDoesNothing() {
        let f = makeFixture(savedPath: sample.path)
        let store = makeStore(script: f.runner, settings: f.settings)
        store.finishForTermination()
        #expect(f.fake.interrupts == 0)
    }

    @Test func recordingStartsWhileScriptRuns() async {
        let f = makeFixture(savedPath: sample.path)
        let store = makeStore(script: f.runner, settings: f.settings)
        await f.runner.toggle()
        await store.startRecording()
        #expect(store.isRecording)
        #expect(f.runner.isRunning)
        store.recordingTask?.cancel()
    }

    @Test func chooseScriptIsIgnoredWhileRunning() async {
        let f = makeFixture(savedPath: sample.path)
        await f.runner.toggle()
        f.fake.picked = URL(fileURLWithPath: "/tmp/other.py")
        await f.runner.chooseScript()
        #expect(f.fake.picks == 0)
        #expect(f.settings.scriptPath == sample.path)
    }

    @Test func chooseScriptSavesNewPathWhenIdle() async {
        let f = makeFixture(savedPath: sample.path)
        let other = URL(fileURLWithPath: "/tmp/other.py")
        f.fake.picked = other
        await f.runner.chooseScript()
        #expect(f.settings.scriptPath == other.path)
        #expect(f.fake.launched.isEmpty)
    }

    // MARK: настройка

    @Test func scriptPathDefaultsToNilAndPersists() throws {
        let suite = "NorthyTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { discardDefaults(defaults, suite: suite) }

        let settings = AppSettings(defaults: defaults)
        #expect(settings.scriptPath == nil)
        settings.scriptPath = sample.path
        #expect(AppSettings(defaults: defaults).scriptPath == sample.path)
    }
}
