import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Картинка из истории буфера: оригинал лежит PNG-файлом в Images/, в JSON —
/// только ссылка. Имя файла — хеш исходных байтов, поэтому повторное
/// копирование той же картинки не плодит копий.
struct ImageRef: Codable, Hashable, Sendable {
    let filename: String
    let pixelWidth: Int
    let pixelHeight: Int
    /// Base64-картинка из clipboard.json старых версий — ждёт переноса в файл.
    var legacyData: Data? = nil

    private enum CodingKeys: String, CodingKey {
        case filename, pixelWidth, pixelHeight
    }
}

nonisolated enum ClipboardImages {

    /// Сохраняет оригинал в каталог (TIFF из буфера перекодируется в PNG).
    /// nil — данные не декодируются как картинка. Потокобезопасно: зовётся
    /// из фоновой задачи, чтобы большой скриншот не подвешивал UI.
    static func store(_ data: Data, in directory: URL) -> ImageRef? {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(source) > 0,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }

        let digest = SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
        let filename = digest + ".png"
        let url = directory.appendingPathComponent(filename)
        if !FileManager.default.fileExists(atPath: url.path) {
            let temp = directory.appendingPathComponent(filename + ".tmp")
            guard let destination = CGImageDestinationCreateWithURL(
                temp as CFURL, UTType.png.identifier as CFString, 1, nil
            ) else { return nil }
            CGImageDestinationAddImageFromSource(destination, source, 0, nil)
            guard CGImageDestinationFinalize(destination) else {
                try? FileManager.default.removeItem(at: temp)
                return nil
            }
            do {
                try FileManager.default.moveItem(at: temp, to: url)
            } catch {
                try? FileManager.default.removeItem(at: temp)
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            }
        }
        return ImageRef(filename: filename, pixelWidth: width, pixelHeight: height)
    }

    /// Уменьшенная копия для списка — декодируется без загрузки оригинала целиком.
    static func thumbnail(at url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
