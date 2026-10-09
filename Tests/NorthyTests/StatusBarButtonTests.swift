import Foundation
import Testing
@testable import Northy

/// Что показывает значок в строке меню: строки лимитов или знак Northy.
@MainActor
struct StatusBarButtonTests {
    private let limits = ["5ч 98%", "7д 49%"]

    @Test func idleShowsLimits() {
        #expect(StatusBarButton.lines(activity: .idle, limits: limits) == limits)
    }

    @Test func idleWithoutLimitsShowsNorthySign() {
        #expect(StatusBarButton.lines(activity: .idle, limits: []) == [])
    }

    @Test func recordingShowsNorthySignInsteadOfLimits() {
        #expect(StatusBarButton.lines(activity: .recording(since: .now), limits: limits) == [])
    }

    @Test func recordingWithoutLimitsShowsNorthySign() {
        #expect(StatusBarButton.lines(activity: .recording(since: .now), limits: []) == [])
    }

    @Test func finishingShowsNorthySignInsteadOfLimits() {
        #expect(StatusBarButton.lines(activity: .finishing, limits: limits) == [])
    }

    @Test func screenshotAndPickerKeepLimits() {
        #expect(StatusBarButton.lines(activity: .capturing(.area), limits: limits) == limits)
        #expect(StatusBarButton.lines(activity: .pickingColor, limits: limits) == limits)
    }

    @Test func stopItemIsActiveWhileRecording() {
        #expect(StatusBarButton.stopItem(activity: .recording(since: .now)) == true)
    }

    @Test func stopItemIsDisabledWhileSaving() {
        #expect(StatusBarButton.stopItem(activity: .finishing) == false)
    }

    @Test func stopItemIsHiddenOutsideRecording() {
        #expect(StatusBarButton.stopItem(activity: .idle) == nil)
        #expect(StatusBarButton.stopItem(activity: .capturing(.recording)) == nil, "окно или область ещё выбираются")
        #expect(StatusBarButton.stopItem(activity: .capturing(.area)) == nil)
        #expect(StatusBarButton.stopItem(activity: .pickingColor) == nil)
    }
}
