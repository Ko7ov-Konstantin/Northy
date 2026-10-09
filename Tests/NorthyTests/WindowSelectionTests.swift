import CoreGraphics
import Testing
@testable import Northy

/// Выбор окна под курсором: порядок окон, свои окна, слои и размер.
struct WindowSelectionTests {
    private func window(_ id: CGWindowID, _ frame: CGRect, layer: Int = 0, pid: pid_t = 100) -> ScreenWindow {
        ScreenWindow(id: id, frame: frame, layer: layer, ownerPID: pid)
    }

    @Test func frontmostWindowWinsWhereTwoOverlap() {
        let windows = [
            window(1, CGRect(x: 0, y: 0, width: 200, height: 200)),
            window(2, CGRect(x: 100, y: 100, width: 200, height: 200)),
        ]
        let picked = WindowSelection.window(at: CGPoint(x: 150, y: 150), in: windows, excludingPID: 1)
        #expect(picked?.id == 1)
    }

    @Test func pointOnlyInBackWindowPicksIt() {
        let windows = [
            window(1, CGRect(x: 0, y: 0, width: 200, height: 200)),
            window(2, CGRect(x: 100, y: 100, width: 200, height: 200)),
        ]
        let picked = WindowSelection.window(at: CGPoint(x: 250, y: 250), in: windows, excludingPID: 1)
        #expect(picked?.id == 2)
    }

    @Test func pointOutsideAllWindowsPicksNothing() {
        let windows = [window(1, CGRect(x: 0, y: 0, width: 200, height: 200))]
        #expect(WindowSelection.window(at: CGPoint(x: 900, y: 900), in: windows, excludingPID: 1) == nil)
    }

    @Test func ownWindowIsSkipped() {
        let windows = [
            window(1, CGRect(x: 0, y: 0, width: 200, height: 200), pid: 999),
            window(2, CGRect(x: 0, y: 0, width: 200, height: 200), pid: 100),
        ]
        let picked = WindowSelection.window(at: CGPoint(x: 50, y: 50), in: windows, excludingPID: 999)
        #expect(picked?.id == 2)
    }

    @Test func nonNormalLayerIsSkipped() {
        let windows = [
            window(1, CGRect(x: 0, y: 0, width: 200, height: 24), layer: 25),
            window(2, CGRect(x: 0, y: 0, width: 200, height: 200)),
        ]
        let picked = WindowSelection.window(at: CGPoint(x: 50, y: 10), in: windows, excludingPID: 1)
        #expect(picked?.id == 2)
    }

    @Test func windowSmallerThanFortyPointsIsSkipped() {
        let windows = [window(1, CGRect(x: 0, y: 0, width: 30, height: 30))]
        #expect(WindowSelection.window(at: CGPoint(x: 10, y: 10), in: windows, excludingPID: 1) == nil)
    }

    @Test func fortyPointWindowIsPicked() {
        let windows = [window(1, CGRect(x: 0, y: 0, width: 40, height: 40))]
        #expect(WindowSelection.window(at: CGPoint(x: 10, y: 10), in: windows, excludingPID: 1)?.id == 1)
    }

    @Test func viewRectFlipsYToAppKitOrigin() {
        let rect = WindowSelection.viewRect(for: CGRect(x: 100, y: 50, width: 400, height: 300), screenHeight: 900)
        #expect(rect == CGRect(x: 100, y: 550, width: 400, height: 300))
    }
}
