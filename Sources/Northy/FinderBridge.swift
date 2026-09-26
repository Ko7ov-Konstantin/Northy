import Foundation
import Security

/// Мост с расширением Finder («Отправить в Northy» / «Вставить из Northy»).
///
/// Расширение живёт в песочнице: оно читает только файл состояния Northy
/// (секрет + свежие файлы полки) и шлёт команды distributed-уведомлением.
/// Секрет в команде отсекает чужие приложения из песочниц: файл им не виден,
/// значит, заставить Northy скопировать ваши файлы к себе они не могут.
nonisolated enum FinderBridge {
    static let requestNotification = Notification.Name("com.kotov.northy.finder.request")
    static let stateFilename = "finder-bridge.json"
    static let recentWindow: TimeInterval = 10 * 60

    struct State: Codable, Equatable {
        struct Item: Codable, Equatable {
            let path: String
            let name: String
            /// Секунды с 1970 — расширение само отбирает файлы за последние 10 минут.
            let addedAt: Double
        }
        let token: String
        let recent: [Item]
    }

    enum Request: Equatable {
        case send([URL])
        case paste(into: URL)
    }

    enum PasteError: LocalizedError, Equatable {
        case notADirectory
        case protectedLocation

        var errorDescription: String? {
            switch self {
            case .notADirectory: "Вставить можно только в папку"
            case .protectedLocation: "В эту папку Northy файлы не вставляет"
            }
        }
    }

    static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Секрет — 0600: читают владелец и расширение (у него исключение песочницы на эту папку).
    static func writeState(token: String, recent: [(url: URL, addedAt: Date)], to url: URL) throws {
        let state = State(token: token, recent: recent.map {
            State.Item(path: $0.url.path, name: $0.url.lastPathComponent, addedAt: $0.addedAt.timeIntervalSince1970)
        })
        let data = try JSONEncoder().encode(state)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private struct RawRequest: Decodable {
        let token: String
        let action: String
        let paths: [String]
    }

    /// nil — не наш секрет, неизвестное действие или подозрительные пути.
    static func parseRequest(_ json: String, token: String) -> Request? {
        guard let raw = try? JSONDecoder().decode(RawRequest.self, from: Data(json.utf8)),
              constantTimeEqual(raw.token, token),
              !raw.paths.isEmpty, raw.paths.count <= 500,
              raw.paths.allSatisfy({ $0.hasPrefix("/") })
        else { return nil }
        let urls = raw.paths.map { URL(fileURLWithPath: $0).standardizedFileURL }
        switch raw.action {
        case "send": return .send(urls)
        case "paste": return urls.count == 1 ? .paste(into: urls[0]) : nil
        default: return nil
        }
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count, !a.isEmpty else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// Как Finder: «a.png» → «a 2.png» → «a 3.png».
    static func uniqueDestination(for name: String, in directory: URL, exists: (URL) -> Bool) -> URL {
        let candidate = directory.appendingPathComponent(name)
        guard exists(candidate) else { return candidate }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var index = 2
        while true {
            let numbered = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            let url = directory.appendingPathComponent(numbered)
            if !exists(url) { return url }
            index += 1
        }
    }

    /// Копирует файлы в папку, не перезаписывая существующие. Контейнеры
    /// песочниц (~/Library/Containers, Group Containers) — не цель.
    static func paste(_ files: [URL], into directory: URL) throws -> [URL] {
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library").standardizedFileURL.path
        let target = directory.standardizedFileURL.path
        if target.hasPrefix(library + "/Containers") || target.hasPrefix(library + "/Group Containers") {
            throw PasteError.protectedLocation
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw PasteError.notADirectory
        }
        return try files.map { file in
            let destination = uniqueDestination(for: file.lastPathComponent, in: directory) {
                FileManager.default.fileExists(atPath: $0.path)
            }
            try FileManager.default.copyItem(at: file, to: destination)
            return destination
        }
    }
}
