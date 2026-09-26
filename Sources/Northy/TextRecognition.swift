import CoreGraphics
import CoreText
import Foundation
import Vision

/// Текст с картинки из истории буфера — локально, через Vision (без сети).
/// Русский и английский: скриншоты ошибок, кусок интерфейса, фото документа.
nonisolated enum TextRecognition {
    enum Failure: LocalizedError, Equatable {
        case noText

        var errorDescription: String? {
            switch self {
            case .noText: "Текст на картинке не найден"
            }
        }
    }

    private static func makeRequest() -> RecognizeTextRequest {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = [Locale.Language(identifier: "ru-RU"), Locale.Language(identifier: "en-US")]
        request.usesLanguageCorrection = true
        return request
    }

    @concurrent
    static func recognizeText(at url: URL) async throws -> String {
        let observations = try await makeRequest().perform(on: url)
        // Строки — сверху вниз, как на картинке (у Vision y растёт вверх).
        let lines = observations
            .sorted { $0.boundingBox.origin.y > $1.boundingBox.origin.y }
            .compactMap { $0.topCandidates(1).first?.string }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty else { throw Failure.noText }
        return lines.joined(separator: "\n")
    }

    // MARK: - Прогрев

    /// Первое распознавание после простоя или перезагрузки ~30 с: macOS загружает
    /// модель. Прогрев — то же распознавание служебной картинки заранее, в фоне.
    static let warmUpInterval: TimeInterval = 15 * 60

    static func shouldWarmUp(hasImages: Bool, lastWarmUp: Date?, now: Date = .now) -> Bool {
        guard hasImages else { return false }
        guard let lastWarmUp else { return true }
        return now.timeIntervalSince(lastWarmUp) >= warmUpInterval
    }

    /// Белая картинка с чёрным словом — модели распознавания есть что читать.
    static func warmUpImage() -> CGImage? {
        let width = 320, height = 80
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, 40, nil)
        let text = NSAttributedString(string: "Northy Текст", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ])
        context.textPosition = CGPoint(x: 12, y: 24)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        return context.makeImage()
    }

    @concurrent
    static func warmUp() async {
        guard let image = warmUpImage() else { return }
        _ = try? await makeRequest().perform(on: image)
    }
}
