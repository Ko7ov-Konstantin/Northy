import CoreGraphics
import Testing
@testable import Northy

/// Геометрия выделения области: координаты AppKit → прямоугольник с началом сверху слева.
struct AreaSelectionTests {
    @Test func dragUpAndRightGivesTopLeftRect() {
        let rect = AreaSelection.rect(from: CGPoint(x: 100, y: 700), to: CGPoint(x: 400, y: 500), screenHeight: 900)
        #expect(rect == CGRect(x: 100, y: 200, width: 300, height: 200))
    }

    @Test func reversedDragGivesSameRect() {
        let rect = AreaSelection.rect(from: CGPoint(x: 400, y: 500), to: CGPoint(x: 100, y: 700), screenHeight: 900)
        #expect(rect == CGRect(x: 100, y: 200, width: 300, height: 200))
    }

    @Test func fractionalCoordinatesAreRounded() {
        let rect = AreaSelection.rect(from: CGPoint(x: 100.4, y: 700.6), to: CGPoint(x: 400.6, y: 500.4), screenHeight: 900)
        #expect(rect == CGRect(x: 100, y: 199, width: 300, height: 200))
    }

    @Test func tooSmallSelectionIsNil() {
        #expect(AreaSelection.rect(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 10, y: 300), screenHeight: 900) == nil)
        #expect(AreaSelection.rect(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 300, y: 10), screenHeight: 900) == nil)
        #expect(AreaSelection.rect(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 50, y: 50), screenHeight: 900) == nil, "одиночный клик")
    }

    @Test func sixteenBySixteenIsEnough() {
        #expect(AreaSelection.rect(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 16, y: 16), screenHeight: 900) != nil)
    }

    @Test func pixelSizeDoublesPointsOnRetina() {
        let size = AreaSelection.pixelSize(CGSize(width: 300, height: 200), scale: 2)
        #expect(size.width == 600)
        #expect(size.height == 400)
    }

    @Test func pixelSizeMakesDimensionsEven() {
        let size = AreaSelection.pixelSize(CGSize(width: 301, height: 201), scale: 1)
        #expect(size.width == 300)
        #expect(size.height == 200)
    }

    @Test func pixelSizeRoundsBeforeMakingEven() {
        let size = AreaSelection.pixelSize(CGSize(width: 150.5, height: 100), scale: 2)
        #expect(size.width == 300, "301 → 300")
        #expect(size.height == 200)
    }

    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let button = CGSize(width: 140, height: 32)

    @Test func startButtonSitsCenteredBelowSelection() {
        let origin = AreaSelection.startButtonOrigin(below: CGRect(x: 100, y: 300, width: 400, height: 200), size: button, in: screen)
        #expect(origin == CGPoint(x: 230, y: 256))
    }

    @Test func startButtonMovesInsideWhenNoRoomBelow() {
        let origin = AreaSelection.startButtonOrigin(below: CGRect(x: 100, y: 10, width: 400, height: 200), size: button, in: screen)
        #expect(origin == CGPoint(x: 230, y: 22))
    }

    @Test func startButtonStaysOnScreenHorizontally() {
        let left = AreaSelection.startButtonOrigin(below: CGRect(x: 0, y: 300, width: 40, height: 200), size: button, in: screen)
        #expect(left.x == 8)
        let right = AreaSelection.startButtonOrigin(below: CGRect(x: 1400, y: 300, width: 40, height: 200), size: button, in: screen)
        #expect(right.x == 1292)
    }
}
