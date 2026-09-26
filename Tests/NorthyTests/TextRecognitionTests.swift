import AppKit
import Foundation
import Testing
@testable import Northy

@MainActor
/// Распознавание текста на картинке из истории буфера (Vision, локально).
struct TextRecognitionTests {

    /// PNG с крупным текстом на белом фоне — как скриншот сообщения об ошибке.
    private func imageWithText(_ lines: [String]) throws -> URL {
        let size = NSSize(width: 900, height: 120 * CGFloat(lines.count) + 40)
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 64, weight: .medium),
            .foregroundColor: NSColor.black,
        ]
        for (index, line) in lines.enumerated() {
            let y = size.height - 120 * CGFloat(index + 1)
            NSAttributedString(string: line, attributes: attributes).draw(at: NSPoint(x: 30, y: y))
        }
        NSGraphicsContext.restoreGraphicsState()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ocr-\(UUID().uuidString).png")
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
        return url
    }

    @Test func recognizesRussianAndEnglishLines() async throws {
        let url = try imageWithText(["Northy error 404", "Ошибка сборки"])
        let text = try await TextRecognition.recognizeText(at: url)
        #expect(text.contains("Northy"))
        #expect(text.contains("404"))
        #expect(text.localizedCaseInsensitiveContains("ошибка"))
        #expect(text.components(separatedBy: "\n").count >= 2, "строки картинки — строки текста")
    }

    @Test func imageWithoutTextGivesNothingFound() async throws {
        let url = try imageWithText([])
        await #expect(throws: TextRecognition.Failure.noText) {
            try await TextRecognition.recognizeText(at: url)
        }
    }
}
