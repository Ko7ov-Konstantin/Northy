import Foundation
import Testing
@testable import Northy

@MainActor
struct MusicPlayerTests {

    @Test func stateParsesPlayingTrack() throws {
        let raw: [String: Any] = [
            "title": "Song",
            "artist": "Band",
            "artwork": "https://lh3.googleusercontent.com/a=w544-h544",
            "playing": true,
            "position": 12.5,
            "duration": 200.0,
        ]
        let state = try #require(MusicState(scriptResult: raw))
        #expect(state.title == "Song")
        #expect(state.artist == "Band")
        #expect(state.artworkURL?.absoluteString == "https://lh3.googleusercontent.com/a=w544-h544")
        #expect(state.isPlaying)
        #expect(state.progress == 12.5 / 200.0)
    }

    @Test func stateWithoutTrackIsNil() {
        #expect(MusicState(scriptResult: nil) == nil)
        #expect(MusicState(scriptResult: "мусор") == nil)
        #expect(MusicState(scriptResult: ["title": NSNull(), "playing": false]) == nil)
        #expect(MusicState(scriptResult: ["title": "", "playing": false]) == nil)
    }

    @Test func progressIsClampedAndSafeWithoutDuration() throws {
        let noDuration = try #require(MusicState(scriptResult: ["title": "A", "position": 5.0, "duration": 0.0]))
        #expect(noDuration.progress == 0)
        let overshoot = try #require(MusicState(scriptResult: ["title": "A", "position": 500.0, "duration": 100.0]))
        #expect(overshoot.progress == 1)
    }

    @Test func badArtworkURLIsDropped() throws {
        let state = try #require(MusicState(scriptResult: ["title": "A", "artwork": "javascript:alert(1)"]))
        #expect(state.artworkURL == nil, "картинка — только по https")
    }

    @Test func commandsHaveDistinctScripts() {
        let scripts = MusicCommand.allCases.map(\.script)
        #expect(Set(scripts).count == MusicCommand.allCases.count)
        #expect(scripts.allSatisfy { !$0.isEmpty })
    }

    @Test func onlyMusicHostsAreAllowedInsideThePlayer() {
        #expect(MusicPlayer.isAllowed(URL(string: "https://music.youtube.com/watch?v=1")!))
        #expect(MusicPlayer.isAllowed(URL(string: "https://accounts.google.com/signin")!))
        #expect(MusicPlayer.isAllowed(URL(string: "https://www.youtube.com/")!))
        #expect(!MusicPlayer.isAllowed(URL(string: "https://example.com/")!))
        #expect(!MusicPlayer.isAllowed(URL(string: "http://music.youtube.com/")!))
        #expect(!MusicPlayer.isAllowed(URL(string: "https://music.youtube.com.evil.com/")!))
    }

    @Test func musicTabIsLastAndOptional() throws {
        #expect(PanelTab.allCases.last == .music)
        #expect(PanelTab.music.title == "Музыка")
        let suite = "NorthyTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { discardDefaults(defaults, suite: suite) }
        #expect(AppSettings(defaults: defaults).enabledTabs == [.clipboard], "по умолчанию выключена")
        defaults.set(["music"], forKey: "panel.enabledTabs")
        #expect(AppSettings(defaults: defaults).enabledTabs == [.clipboard, .music])
    }
}
