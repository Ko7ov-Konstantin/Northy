import Foundation
import Testing
@testable import Northy

@MainActor
/// Веб-источник лимитов (как веб-режим CodexBar): разбор cookies Safari,
/// выбор сессии и организации, запросы и ответы — без сети и без реальных cookies.
struct ClaudeWebTests {

    struct FixtureCookie {
        var domain: String
        var name: String
        var path = "/"
        var value: String
        var expires: Date
    }

    /// Файл в формате Safari: "cook", число страниц и их размеры (big-endian),
    /// страницы с cookie (little-endian), даты — секунды от 2001-01-01.
    static func binaryCookies(pages: [[FixtureCookie]]) -> Data {
        func le32(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian, Array.init) }
        func be32(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.bigEndian, Array.init) }
        func leDouble(_ v: Double) -> [UInt8] { withUnsafeBytes(of: v.bitPattern.littleEndian, Array.init) }

        func cookieBytes(_ c: FixtureCookie) -> [UInt8] {
            let strings = [c.domain, c.name, c.path, c.value].map { Array($0.utf8) + [0] }
            var offsets: [UInt32] = []
            var cursor = 56
            for s in strings {
                offsets.append(UInt32(cursor))
                cursor += s.count
            }
            var bytes: [UInt8] = []
            bytes += le32(UInt32(cursor))
            bytes += le32(0)
            bytes += le32(1)
            bytes += le32(0)
            offsets.forEach { bytes += le32($0) }
            bytes += [UInt8](repeating: 0, count: 8)
            bytes += leDouble(c.expires.timeIntervalSinceReferenceDate)
            bytes += leDouble(0)
            strings.forEach { bytes += $0 }
            return bytes
        }

        func pageBytes(_ cookies: [FixtureCookie]) -> [UInt8] {
            let bodies = cookies.map(cookieBytes)
            var header: [UInt8] = [0, 0, 1, 0] + le32(UInt32(cookies.count))
            var offset = 4 + 4 + 4 * cookies.count + 4
            for body in bodies {
                header += le32(UInt32(offset))
                offset += body.count
            }
            header += le32(0)
            return header + bodies.flatMap { $0 }
        }

        let pagesBytes = pages.map(pageBytes)
        var data: [UInt8] = Array("cook".utf8) + be32(UInt32(pages.count))
        pagesBytes.forEach { data += be32(UInt32($0.count)) }
        pagesBytes.forEach { data += $0 }
        data += [UInt8](repeating: 0, count: 12)
        return Data(data)
    }

    private let future = Date(timeIntervalSinceNow: 86_400 * 30)
    private let orgID = "1b2c3d4e-0000-4000-8000-00000000abcd"

    // MARK: Cookies.binarycookies

    @Test func parsesCookiesAcrossPages() throws {
        let data = Self.binaryCookies(pages: [
            [FixtureCookie(domain: ".claude.ai", name: "sessionKey", value: "sk-ant-test", expires: future)],
            [
                FixtureCookie(domain: "example.com", name: "a", value: "1", expires: future),
                FixtureCookie(domain: "claude.ai", name: "lastActiveOrg", value: "org", expires: future),
            ],
        ])
        let cookies = try BinaryCookies.parse(data)
        #expect(cookies.count == 3)
        #expect(cookies[0].name == "sessionKey")
        #expect(cookies[0].value == "sk-ant-test")
        #expect(cookies[0].domain == ".claude.ai")
        #expect(abs(cookies[0].expires.timeIntervalSince(future)) < 1)
        #expect(cookies[2].domain == "claude.ai")
    }

    @Test func rejectsNonCookieFile() {
        #expect(throws: BinaryCookies.ParseError.self) { try BinaryCookies.parse(Data("nope".utf8)) }
        #expect(throws: BinaryCookies.ParseError.self) { try BinaryCookies.parse(Data("cook".utf8) + Data([0, 0, 0, 5])) }
    }

    @Test func truncatedFileNeverCrashes() {
        let full = Self.binaryCookies(pages: [[FixtureCookie(domain: ".claude.ai", name: "sessionKey", value: "sk-ant-x", expires: future)]])
        for length in 0..<full.count {
            _ = try? BinaryCookies.parse(full.prefix(length))
        }
    }

    // MARK: выбор сессии

    @Test func picksLiveClaudeSessionKeyOnly() {
        let now = Date()
        func cookie(_ domain: String, _ name: String, _ value: String, _ expires: Date) -> BinaryCookies.Cookie {
            BinaryCookies.Cookie(domain: domain, name: name, path: "/", value: value, expires: expires)
        }
        #expect(ClaudeWeb.sessionKey(in: [cookie(".claude.ai", "sessionKey", " sk-ant-live ", now + 60)], now: now) == "sk-ant-live")
        #expect(ClaudeWeb.sessionKey(in: [cookie("claude.ai", "sessionKey", "sk-ant-old", now - 60)], now: now) == nil, "истёкшая")
        #expect(ClaudeWeb.sessionKey(in: [cookie(".notclaude.ai", "sessionKey", "sk-ant-x", now + 60)], now: now) == nil, "чужой домен")
        #expect(ClaudeWeb.sessionKey(in: [cookie(".claude.ai", "sessionKey", "garbage", now + 60)], now: now) == nil, "не похоже на ключ")
        #expect(ClaudeWeb.sessionKey(in: [cookie(".claude.ai", "other", "sk-ant-x", now + 60)], now: now) == nil)
    }

    // MARK: организация

    @Test func prefersChatOrganization() throws {
        let json = """
        [{"uuid":"aaaaaaaa-0000-4000-8000-000000000001","capabilities":["api"]},
         {"uuid":"\(orgID)","capabilities":["chat","claude_max"]}]
        """
        #expect(try ClaudeWeb.organizationID(from: Data(json.utf8)) == orgID)
    }

    @Test func fallsBackToNonApiThenFirst() throws {
        let nonApi = #"[{"uuid":"aaaaaaaa-0000-4000-8000-000000000001","capabilities":["api"]},{"uuid":"\#(orgID)"}]"#
        #expect(try ClaudeWeb.organizationID(from: Data(nonApi.utf8)) == orgID)
        let onlyApi = #"[{"uuid":"\#(orgID)","capabilities":["api"]}]"#
        #expect(try ClaudeWeb.organizationID(from: Data(onlyApi.utf8)) == orgID)
        #expect(throws: (any Error).self) { try ClaudeWeb.organizationID(from: Data("[]".utf8)) }
    }

    @Test func organizationIDMustBeUUID() {
        let evil = #"[{"uuid":"../../account","capabilities":["chat"]}]"#
        #expect(throws: (any Error).self) { try ClaudeWeb.organizationID(from: Data(evil.utf8)) }
    }

    // MARK: запрос

    @Test func requestsGoOnlyToClaudeWithSessionCookie() {
        let request = ClaudeWeb.request(path: "/api/organizations/\(orgID)/usage", sessionKey: "sk-ant-abc")
        #expect(request.url?.absoluteString == "https://claude.ai/api/organizations/\(orgID)/usage")
        #expect(request.value(forHTTPHeaderField: "Cookie") == "sessionKey=sk-ant-abc")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.timeoutInterval == 15)
    }

    // MARK: ответы

    @Test func parsesUsage() throws {
        let json = """
        {"five_hour":{"utilization":37,"resets_at":"2026-09-26T21:00:00.123456+00:00"},
         "seven_day":{"utilization":12.5,"resets_at":"2026-10-01T10:00:00+00:00"},
         "seven_day_opus":null,
         "seven_day_sonnet":{"utilization":5,"resets_at":null},
         "extra_usage":{"is_enabled":false}}
        """
        let now = Date(timeIntervalSince1970: 1)
        let snapshot = try ClaudeWeb.parseUsage(Data(json.utf8), now: now)
        #expect(snapshot.windows.map(\.kind) == [.session, .weekly, .model("Sonnet")])
        #expect(snapshot.headline?.percent == 37)
        let expected = try #require(ISO8601DateFormatter().date(from: "2026-09-26T21:00:00Z"))
        #expect(abs((snapshot.headline?.resetsAt ?? .distantPast).timeIntervalSince(expected)) < 1)
        #expect(snapshot.windows[1].percent == 12.5)
        #expect(snapshot.fetchedAt == now)
    }

    /// Лимиты на отдельную модель (Fable и т.п.) приходят в массиве limits,
    /// как их разбирает CodexBar: kind "weekly_scoped", имя — scope.model.display_name.
    @Test func parsesModelScopedWeeklyLimits() throws {
        let json = """
        {"five_hour":{"utilization":10,"resets_at":null},
         "seven_day":{"utilization":20,"resets_at":null},
         "seven_day_sonnet":{"utilization":3,"resets_at":null},
         "limits":[
           {"kind":"weekly_scoped","group":"weekly","percent":64,"resets_at":"2026-10-01T10:00:00+00:00",
            "scope":{"model":{"id":"claude-fable","display_name":"Fable"}}},
           {"kind":"weekly_scoped","group":"weekly","percent":20,"scope":{"model":{"id":"all-models","display_name":"All models"}}},
           {"kind":"weekly_scoped","group":"weekly","percent":3,"scope":{"model":{"display_name":"Sonnet"}}},
           {"kind":"five_hour","group":"session","percent":10},
           {"kind":"weekly_scoped","group":"weekly","percent":1,"scope":{"model":{"display_name":"  "}}}
         ]}
        """
        let snapshot = try ClaudeWeb.parseUsage(Data(json.utf8), now: .now)
        #expect(snapshot.windows.map(\.kind) == [.session, .weekly, .model("Sonnet"), .model("Fable")],
                "All models — это общая неделя, Sonnet не дублируется, пустое имя пропущено")
        let fable = try #require(snapshot.windows.first { $0.kind == .model("Fable") })
        #expect(fable.percent == 64)
        #expect(fable.resetsAt != nil)
        #expect(fable.title == "Неделя · Fable")
    }

    @Test func nullSessionFallsBackToWeekly() throws {
        let json = #"{"five_hour":null,"seven_day":{"utilization":40,"resets_at":null}}"#
        let snapshot = try ClaudeWeb.parseUsage(Data(json.utf8), now: .now)
        #expect(snapshot.headline?.kind == .weekly)
    }

    @Test func garbageUsageThrows() {
        #expect(throws: (any Error).self) { try ClaudeWeb.parseUsage(Data("<html>".utf8), now: .now) }
        #expect(throws: (any Error).self) { try ClaudeWeb.parseUsage(Data("{}".utf8), now: .now) }
    }

    @Test func mapsHTTPErrors() {
        func response(_ code: Int, _ headers: [String: String] = [:]) -> HTTPURLResponse {
            HTTPURLResponse(url: URL(string: "https://claude.ai")!, statusCode: code, httpVersion: nil, headerFields: headers)!
        }
        #expect(ClaudeWeb.error(for: response(401), body: Data()) == .unauthorized)
        #expect(ClaudeWeb.error(for: response(403), body: Data()) == .unauthorized)
        #expect(ClaudeWeb.error(for: response(403, ["cf-mitigated": "challenge"]), body: Data()) == .cloudflare)
        #expect(ClaudeWeb.error(for: response(403), body: Data("<title>Just a moment...</title>".utf8)) == .cloudflare)
        #expect(ClaudeWeb.error(for: response(429), body: Data()) == .rateLimited)
        #expect(ClaudeWeb.error(for: response(500), body: Data()) == .server(500))
    }
}
