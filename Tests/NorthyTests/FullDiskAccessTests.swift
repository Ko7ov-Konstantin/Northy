import Foundation
import Testing
@testable import Northy

struct FullDiskAccessTests {
    private let files = [URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/b")]

    private func denied() -> NSError {
        NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
    }

    private func missing() -> NSError {
        NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)
    }

    @Test func readableFileMeansGranted() {
        let status = FullDiskAccess.status(probing: files) { url in
            if url.path == "/a" { throw missing() }
        }
        #expect(status == .granted)
    }

    @Test func permissionErrorMeansDenied() {
        let status = FullDiskAccess.status(probing: files) { url in
            throw url.path == "/a" ? denied() : missing()
        }
        #expect(status == .denied)
    }

    /// Нет ни одного файла (Safari не запускали) — судить не по чему, не пристаём.
    @Test func nothingToProbeIsUnknown() {
        let status = FullDiskAccess.status(probing: files) { _ in throw missing() }
        #expect(status == .unknown)
    }

    @Test func settingsLinkPointsToFullDiskAccessPane() {
        #expect(FullDiskAccess.settingsURL.absoluteString.hasPrefix("x-apple.systempreferences:"))
        #expect(FullDiskAccess.settingsURL.absoluteString.hasSuffix("Privacy_AllFiles"))
    }
}
