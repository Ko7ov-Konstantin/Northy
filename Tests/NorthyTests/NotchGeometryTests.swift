import Foundation
import Testing
@testable import Northy

@MainActor
/// Фолбэк-фреймы считаются чистыми функциями без NSScreen — основной экран
/// без выреза и вовсе без экранов покрываются тестами.
struct NotchGeometryTests {

    private let notch = CGRect(x: 500, y: 1000, width: 200, height: 38)
    private let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)

    // MARK: collapsed

    @Test func collapsedHugsNotchPlusExtraHeight() {
        let frame = NotchGeometry.collapsedFrame(notch: notch, fallbackScreen: screen)
        #expect(frame.minX == 500)
        #expect(frame.width == 200)
        #expect(frame.height == 38 + NotchGeometry.collapsedExtraHeight)
        // Низ свёрнутой панели ниже выреза на запас.
        #expect(frame.maxY == notch.maxY)
    }

    @Test func collapsedFallbackCentersOnTopOfScreen() {
        let frame = NotchGeometry.collapsedFrame(notch: nil, fallbackScreen: screen)
        #expect(frame.width == NotchGeometry.fallbackSize.width)
        #expect(frame.height == NotchGeometry.fallbackSize.height)
        #expect(frame.midX == screen.midX)
        #expect(frame.maxY == screen.maxY, "свёрнутая полка прижата к верху экрана")
    }

    @Test func collapsedWithoutScreenFallsBackToZeroOrigin() {
        let frame = NotchGeometry.collapsedFrame(notch: nil, fallbackScreen: nil)
        #expect(frame == CGRect(origin: .zero, size: NotchGeometry.fallbackSize))
    }

    // MARK: expanded

    @Test func expandedCentersOnNotch() {
        let frame = NotchGeometry.expandedFrame(notch: notch, screen: screen, notchHeight: 38)
        #expect(frame.midX == notch.midX)
        #expect(frame.maxY == screen.maxY, "верхняя кромка у верха экрана")
        #expect(frame.width == NotchGeometry.expandedContentSize.width)
        #expect(frame.height == NotchGeometry.expandedContentSize.height + 38)
    }

    @Test func expandedWithoutNotchCentersOnScreen() {
        let frame = NotchGeometry.expandedFrame(notch: nil, screen: screen, notchHeight: 0)
        #expect(frame.midX == screen.midX)
        #expect(frame.height == NotchGeometry.expandedContentSize.height)
    }

    // MARK: растягиваемая панель

    @Test func expandedUsesCustomContentSizeCenteredOnNotch() {
        let frame = NotchGeometry.expandedFrame(notch: notch, screen: screen, notchHeight: 38, contentSize: CGSize(width: 900, height: 500))
        #expect(frame.width == 900)
        #expect(frame.height == 538)
        #expect(frame.midX == notch.midX, "растягивается симметрично от выреза")
        #expect(frame.maxY == screen.maxY)
    }

    @Test func contentSizeIsClampedToMinimumAndScreen() {
        let small = NotchGeometry.clampedContentSize(CGSize(width: 100, height: 50), screen: screen)
        #expect(small == NotchGeometry.minimumContentSize)
        let huge = NotchGeometry.clampedContentSize(CGSize(width: 5000, height: 5000), screen: screen)
        #expect(huge.width == screen.width - 40)
        #expect(huge.height == (screen.height * 0.85).rounded())
        let normal = NotchGeometry.clampedContentSize(CGSize(width: 800.4, height: 420.6), screen: screen)
        #expect(normal == CGSize(width: 800, height: 421), "целые точки — без дрожания при перетаскивании")
    }

    @Test func contentSizePersistsInDefaults() throws {
        let suite = "NorthyTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { discardDefaults(defaults, suite: suite) }
        #expect(NotchGeometry.storedContentSize(in: defaults) == NotchGeometry.expandedContentSize, "по умолчанию — прежний размер")
        NotchGeometry.storeContentSize(CGSize(width: 820, height: 460), in: defaults)
        #expect(NotchGeometry.storedContentSize(in: defaults) == CGSize(width: 820, height: 460))
    }

    @Test func expandedWithoutScreenReturnsContentSizeAtOrigin() {
        let frame = NotchGeometry.expandedFrame(notch: nil, screen: nil, notchHeight: 0)
        #expect(frame == CGRect(origin: .zero, size: NotchGeometry.expandedContentSize))
    }
}
