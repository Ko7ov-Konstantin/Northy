import Foundation
import Testing
@testable import Northy

@MainActor
struct QuickLookTests {
    private let urls = ["a.png", "b.png", "c.png"].map { URL(fileURLWithPath: "/tmp/\($0)") }

    /// Просмотр получает все картинки и открывается на выбранной — дальше стрелками.
    @Test func browsesAllItemsStartingAtChosen() {
        let quickLook = QuickLook()
        quickLook.prepare(urls, startingAt: urls[1])
        #expect(quickLook.numberOfPreviewItems(in: nil) == 3)
        #expect(quickLook.startIndex == 1)
        #expect((quickLook.previewPanel(nil, previewItemAt: 2) as? URL) == urls[2])
    }

    @Test func unknownStartFallsBackToFirst() {
        let quickLook = QuickLook()
        quickLook.prepare(urls, startingAt: URL(fileURLWithPath: "/tmp/x.png"))
        #expect(quickLook.startIndex == 0)
        quickLook.prepare([], startingAt: urls[0])
        #expect(quickLook.numberOfPreviewItems(in: nil) == 0)
    }
}
