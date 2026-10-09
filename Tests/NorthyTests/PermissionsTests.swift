import AVFoundation
import Foundation
import Testing
@testable import Northy

@MainActor
struct PermissionsTests {
    private func checks(
        disk: FullDiskAccess.Status = .granted,
        screen: Bool = true,
        finder: Bool = true,
        microphone: AVAuthorizationStatus = .authorized,
        accessibility: Bool = true,
        onRequest: @escaping @MainActor () -> Void = {}
    ) -> PermissionChecks {
        PermissionChecks(
            fullDiskAccess: { disk },
            screenRecording: { screen },
            finderExtension: { finder },
            microphone: { microphone },
            accessibility: { accessibility },
            requestScreenRecording: onRequest,
            open: { _ in }
        )
    }

    @Test func listContainsAllSix() {
        #expect(Permission.allCases == [.fullDiskAccess, .screenRecording, .microphone, .accessibility, .finderExtension, .keychain])
    }

    @Test func fullDiskAccessStates() {
        #expect(Permission.fullDiskAccess.state(checks(disk: .granted)) == .granted)
        #expect(Permission.fullDiskAccess.state(checks(disk: .denied)) == .denied)
        #expect(Permission.fullDiskAccess.state(checks(disk: .unknown)) == .unknown)
    }

    @Test func screenRecordingStates() {
        #expect(Permission.screenRecording.state(checks(screen: true)) == .granted)
        #expect(Permission.screenRecording.state(checks(screen: false)) == .denied)
    }

    @Test func finderExtensionStates() {
        #expect(Permission.finderExtension.state(checks(finder: true)) == .granted)
        #expect(Permission.finderExtension.state(checks(finder: false)) == .denied)
    }

    @Test func microphoneStates() {
        #expect(Permission.microphone.state(checks(microphone: .authorized)) == .granted)
        #expect(Permission.microphone.state(checks(microphone: .denied)) == .denied)
        #expect(Permission.microphone.state(checks(microphone: .restricted)) == .denied)
        #expect(Permission.microphone.state(checks(microphone: .notDetermined)) == .unknown)
        #expect(Permission.microphone.title == "Микрофон")
    }

    @Test func accessibilityStates() {
        #expect(Permission.accessibility.state(checks(accessibility: true)) == .granted)
        #expect(Permission.accessibility.state(checks(accessibility: false)) == .denied)
        #expect(Permission.accessibility.title == "Универсальный доступ")
    }

    @Test func keychainHasNoActionAndIsNotChecked() {
        #expect(Permission.keychain.state(checks()) == .notChecked)
        #expect(Permission.keychain.hasSettingsAction == false)
        let withAction = Permission.allCases.filter { $0 != .keychain }.allSatisfy { $0.hasSettingsAction }
        #expect(withAction)
    }

    @Test func recheckNeverRequestsPermission() {
        var requested = false
        let c = checks(screen: false) { requested = true }
        for permission in Permission.allCases { _ = permission.state(c) }
        #expect(requested == false)
    }

    @Test func actionsOpenExpectedTargets() {
        var opened: [Permission] = []
        let c = PermissionChecks(
            fullDiskAccess: { .granted }, screenRecording: { true }, finderExtension: { true },
            microphone: { .authorized }, accessibility: { true }, requestScreenRecording: {}, open: { opened.append($0) }
        )
        Permission.screenRecording.openSettings(c)
        Permission.microphone.openSettings(c)
        Permission.keychain.openSettings(c)
        #expect(opened == [.screenRecording, .microphone])
    }
}
