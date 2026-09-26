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

    static func recognizeText(at url: URL) async throws -> String {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = [Locale.Language(identifier: "ru-RU"), Locale.Language(identifier: "en-US")]
        request.usesLanguageCorrection = true
        let observations = try await request.perform(on: url)
        // Строки — сверху вниз, как на картинке (у Vision y растёт вверх).
        let lines = observations
            .sorted { $0.boundingBox.origin.y > $1.boundingBox.origin.y }
            .compactMap { $0.topCandidates(1).first?.string }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty else { throw Failure.noText }
        return lines.joined(separator: "\n")
    }
}
