import AppKit
import Observation

@MainActor
@Observable
final class ShelfStore {
    private(set) var files: [URL] = []

    func add(_ urls: [URL]) {
        for url in urls where !files.contains(where: { $0.path == url.path }) {
            files.append(url)
        }
    }

    func remove(_ url: URL) {
        files.removeAll { $0.path == url.path }
    }

    func clear() {
        files.removeAll()
    }
}
