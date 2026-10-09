import AppKit
import Testing
@testable import Northy

/// Виды выбора области и окна и отсчёт: события мыши и клавиш подаются напрямую, без экрана.
@MainActor
struct RecordingPickersTests {
    private let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)

    private func mouse(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type, location: NSPoint(x: x, y: y), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
    }

    private func escape() throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
        ))
    }

    // MARK: область

    @Test func areaWaitsForStartButton() throws {
        let view = SelectionView(frame: screen)
        var results: [CGRect?] = []
        view.onFinish = { results.append($0) }

        view.mouseDown(with: try mouse(.leftMouseDown, 100, 700))
        view.mouseDragged(with: try mouse(.leftMouseDragged, 300, 600))
        view.mouseUp(with: try mouse(.leftMouseUp, 400, 500))

        #expect(results.isEmpty, "выделение само запись не начинает")
        #expect(!view.startButton.isHidden)
        #expect(view.startButton.frame.midX == 250)
        #expect(view.startButton.frame.maxY == 488, "под выделением с отступом 12")

        view.startButton.performClick(nil)
        #expect(results == [CGRect(x: 100, y: 200, width: 300, height: 200)])
        view.startButton.performClick(nil)
        #expect(results.count == 1, "повторное нажатие ничего не шлёт")
    }

    @Test func accidentalClickSelectsNothing() throws {
        let view = SelectionView(frame: screen)
        var finished = false
        view.onFinish = { _ in finished = true }

        view.mouseDown(with: try mouse(.leftMouseDown, 100, 700))
        view.mouseUp(with: try mouse(.leftMouseUp, 103, 698))

        #expect(view.startButton.isHidden)
        view.startButton.performClick(nil)
        #expect(!finished)
    }

    @Test func newDragReplacesSelection() throws {
        let view = SelectionView(frame: screen)
        var results: [CGRect?] = []
        view.onFinish = { results.append($0) }
        view.mouseDown(with: try mouse(.leftMouseDown, 100, 700))
        view.mouseUp(with: try mouse(.leftMouseUp, 400, 500))

        view.mouseDown(with: try mouse(.leftMouseDown, 600, 400))
        #expect(view.startButton.isHidden, "пока тянут новое выделение, кнопки нет")
        view.mouseUp(with: try mouse(.leftMouseUp, 800, 300))
        view.startButton.performClick(nil)

        #expect(results == [CGRect(x: 600, y: 500, width: 200, height: 100)])
    }

    @Test func escapeCancelsAreaSelection() throws {
        let view = SelectionView(frame: screen)
        var results: [CGRect?] = []
        view.onFinish = { results.append($0) }
        view.mouseDown(with: try mouse(.leftMouseDown, 100, 700))
        view.mouseUp(with: try mouse(.leftMouseUp, 400, 500))

        view.keyDown(with: try escape())

        #expect(results == [nil])
    }

    // MARK: окно

    private func windowView() -> WindowSelectionView {
        let view = WindowSelectionView(frame: screen)
        // Рамки — с началом сверху: окно 7 занимает y 100…400 сверху, то есть 500…800 снизу.
        view.windows = [
            ScreenWindow(id: 7, frame: CGRect(x: 100, y: 100, width: 400, height: 300), layer: 0, ownerPID: 1),
            ScreenWindow(id: 9, frame: CGRect(x: 700, y: 100, width: 400, height: 300), layer: 0, ownerPID: 1),
        ]
        return view
    }

    @Test func windowWaitsForStartButton() throws {
        let view = windowView()
        var results: [CGWindowID?] = []
        view.onFinish = { results.append($0) }

        view.mouseUp(with: try mouse(.leftMouseUp, 300, 650))

        #expect(results.isEmpty, "клик только выбирает окно")
        #expect(!view.startButton.isHidden)
        #expect(view.startButton.frame.midX == 300)
        #expect(view.startButton.frame.maxY == 488)

        view.startButton.performClick(nil)
        #expect(results == [7])
    }

    @Test func clickOnAnotherWindowChangesChoice() throws {
        let view = windowView()
        var results: [CGWindowID?] = []
        view.onFinish = { results.append($0) }

        view.mouseUp(with: try mouse(.leftMouseUp, 300, 650))
        view.mouseUp(with: try mouse(.leftMouseUp, 900, 650))
        view.startButton.performClick(nil)

        #expect(results == [9])
    }

    @Test func hoverAfterChoiceDoesNotChangeIt() throws {
        let view = windowView()
        var results: [CGWindowID?] = []
        view.onFinish = { results.append($0) }

        view.mouseUp(with: try mouse(.leftMouseUp, 300, 650))
        view.mouseMoved(with: try mouse(.mouseMoved, 900, 650))
        view.startButton.performClick(nil)

        #expect(results == [7], "пишется выбранное окно, а не то, над которым курсор")
    }

    @Test func clickPastWindowsClearsChoice() throws {
        let view = windowView()
        var finished = false
        view.onFinish = { _ in finished = true }

        view.mouseUp(with: try mouse(.leftMouseUp, 300, 650))
        view.mouseUp(with: try mouse(.leftMouseUp, 600, 100))

        #expect(view.startButton.isHidden)
        view.startButton.performClick(nil)
        #expect(!finished)
    }

    @Test func escapeCancelsWindowSelection() throws {
        let view = windowView()
        var results: [CGWindowID?] = []
        view.onFinish = { results.append($0) }
        view.mouseUp(with: try mouse(.leftMouseUp, 300, 650))

        view.keyDown(with: try escape())

        #expect(results == [nil])
    }

    // MARK: отсчёт

    @Test func countdownCountsDownAndStarts() async {
        let view = CountdownView(frame: screen)
        let clock = ContinuousClock()
        let started = clock.now

        let start = await view.run(from: 3, tick: .milliseconds(40))

        #expect(start)
        #expect(view.number.stringValue == "1", "последняя показанная цифра")
        #expect(clock.now - started >= .milliseconds(120), "три шага отсчёта")
    }

    @Test func skipStartsImmediately() async {
        let view = CountdownView(frame: screen)
        Task {
            while view.number.stringValue.isEmpty { await Task.yield() }
            view.skipButton.performClick(nil)
        }

        let start = await view.run(from: 3, tick: .seconds(60))

        #expect(start)
        #expect(view.number.stringValue == "3", "пропуск не ждёт следующих цифр")
    }

    @Test func cancelButtonStopsCountdown() async {
        let view = CountdownView(frame: screen)
        Task {
            while view.number.stringValue.isEmpty { await Task.yield() }
            view.cancelButton.performClick(nil)
        }

        let start = await view.run(from: 3, tick: .seconds(60))

        #expect(!start)
        #expect(!view.cancelButton.frame.intersects(view.skipButton.frame), "кнопки не накладываются")
        #expect(view.cancelButton.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua, "на тёмной плашке кнопки тёмной темы — текст светлый и при светлой теме системы")
    }

    @Test func escapeCancelsCountdown() async throws {
        let view = CountdownView(frame: screen)
        let key = try escape()
        Task {
            while view.number.stringValue.isEmpty { await Task.yield() }
            view.keyDown(with: key)
        }

        let start = await view.run(from: 3, tick: .seconds(60))

        #expect(!start)
    }
}
