import Foundation
import Testing
@testable import Northy

struct CodexCLITests {
    @Test func readsAccountWindowsAfterHandshake() async throws {
        let binary = try fixture(reply: """
        {"method":"account/rateLimits/updated","params":{}}
        {"id":1,"result":{"rateLimits":{"limitId":"codex","planType":"plus","primary":{"usedPercent":30,"windowDurationMins":300,"resetsAt":1795125352},"secondary":{"usedPercent":5,"windowDurationMins":10080,"resetsAt":1795712152}}}}
        """)
        defer { try? FileManager.default.removeItem(at: binary) }
        let snapshot = try await CodexCLI.fetch(binary: binary)

        #expect(snapshot.plan == "Plus")
        #expect(snapshot.windows.map(\.kind) == [.session, .weekly])
        #expect(snapshot.statusBarLines == ["5ч 70%", "7д 95%"])
        #expect(snapshot.windows.map(\.resetsAt) == [Date(timeIntervalSince1970: 1795125352), Date(timeIntervalSince1970: 1795712152)])
    }

    @Test func usesDurationToIdentifyASingleWeeklyWindow() async throws {
        let binary = try fixture(reply: """
        {"id":1,"result":{"rateLimits":{"primary":{"usedPercent":72,"windowDurationMins":10080},"secondary":null}}}
        """)
        defer { try? FileManager.default.removeItem(at: binary) }
        let snapshot = try await CodexCLI.fetch(binary: binary)

        #expect(snapshot.windows.map(\.kind) == [.weekly])
        #expect(snapshot.statusBarLines == ["7д 28%"])
        #expect(snapshot.windows.first?.resetsAt == nil)
    }

    @Test func emptyQuotasAndSilentCLIReportAnError() async throws {
        let empty = try fixture(reply: """
        {"id":1,"result":{"rateLimits":{"primary":null,"secondary":null}}}
        """)
        defer { try? FileManager.default.removeItem(at: empty) }
        await #expect(throws: CodexCLI.FetchError.noWindows) {
            try await CodexCLI.fetch(binary: empty)
        }

        let silent = try fixture(reply: "")
        defer { try? FileManager.default.removeItem(at: silent) }
        await #expect(throws: CodexCLI.FetchError.timedOut) {
            try await CodexCLI.fetch(binary: silent, timeout: .milliseconds(150))
        }
    }

    @Test func startsTheBrowserLoginCommandWithoutAPIKeyArguments() async throws {
        let binary = try fixture(script: """
        #!/bin/sh
        [ "$#" -eq 1 ] && [ "$1" = login ]
        """)
        defer { try? FileManager.default.removeItem(at: binary) }
        try await CodexCLI.login(binary: binary)
    }

    private func fixture(reply: String) throws -> URL {
        try fixture(script: """
        #!/bin/sh
        IFS= read -r request
        case "$request" in *'"method":"initialize"'*) ;; *) exit 1 ;; esac
        printf '%s\\n' '{"id":0,"result":{}}'
        IFS= read -r request
        case "$request" in *'"method":"initialized"'*) ;; *) exit 1 ;; esac
        IFS= read -r request
        case "$request" in *'"method":"account/rateLimits/read"'*) ;; *) exit 1 ;; esac
        printf '%s\\n' '\(reply)'
        IFS= read -r request
        """)
    }

    private func fixture(script: String) throws -> URL {
        let binary = FileManager.default.temporaryDirectory.appendingPathComponent("northy-codex-\(UUID().uuidString)")
        try script.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        return binary
    }
}
