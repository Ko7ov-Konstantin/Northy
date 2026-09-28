import AppKit
import Foundation
import Observation
import WebKit

/// Что сейчас играет в YouTube Music; nil — трека нет.
struct MusicState: Equatable {
    var title: String
    var artist: String
    var artworkURL: URL?
    var isPlaying: Bool
    var position: Double
    var duration: Double

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(position / duration, 0), 1)
    }

    init?(scriptResult: Any?) {
        guard let dict = scriptResult as? [String: Any],
              let title = dict["title"] as? String, !title.isEmpty
        else { return nil }
        self.title = title
        artist = dict["artist"] as? String ?? ""
        artworkURL = (dict["artwork"] as? String)
            .flatMap(URL.init(string:))
            .flatMap { $0.scheme == "https" ? $0 : nil }
        isPlaying = (dict["playing"] as? NSNumber)?.boolValue ?? false
        position = (dict["position"] as? NSNumber)?.doubleValue ?? 0
        duration = (dict["duration"] as? NSNumber)?.doubleValue ?? 0
    }
}

enum MusicCommand: CaseIterable {
    case playPause, next, previous

    /// Кнопки плеера сайта — так команда проходит теми же путями, что и клик мышью.
    var script: String {
        switch self {
        case .playPause:
            "(() => { const v = document.querySelector('video'); if (!v) return; v.paused ? v.play() : v.pause(); })()"
        case .next:
            "document.querySelector('ytmusic-player-bar .next-button')?.click()"
        case .previous:
            "document.querySelector('ytmusic-player-bar .previous-button')?.click()"
        }
    }
}

/// Веб-плеер music.youtube.com с постоянной сессией Google: вход выполняется
/// один раз на странице Google, пароль и токены приложением не читаются.
@MainActor
@Observable
final class MusicPlayer: NSObject {
    private(set) var state: MusicState?
    private(set) var errorMessage: String?

    @ObservationIgnored let webView: WKWebView

    private static let home = URL(string: "https://music.youtube.com")!
    private static let allowedDomains = ["youtube.com", "google.com"]
    private static let stateScript = """
    (() => {
      const v = document.querySelector('video');
      const m = navigator.mediaSession && navigator.mediaSession.metadata;
      const art = m && m.artwork && m.artwork.length ? m.artwork[m.artwork.length - 1].src : null;
      return {
        title: m ? m.title : null,
        artist: m ? m.artist : null,
        artwork: art,
        playing: v ? !v.paused : false,
        position: v ? v.currentTime : 0,
        duration: v && isFinite(v.duration) ? v.duration : 0
      };
    })()
    """

    static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return allowedDomains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        // Google не пускает на вход во встроенные браузеры с «чужим» User-Agent.
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.load(URLRequest(url: Self.home))
    }

    func send(_ command: MusicCommand) {
        webView.evaluateJavaScript(command.script, completionHandler: nil)
    }

    func refreshState() async {
        let result = try? await webView.evaluateJavaScript(Self.stateScript)
        let new = MusicState(scriptResult: result)
        if new != state { state = new }
    }

    func reload() {
        errorMessage = nil
        webView.load(URLRequest(url: Self.home))
    }
}

extension MusicPlayer: WKNavigationDelegate, WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard navigationAction.targetFrame?.isMainFrame ?? true, let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        if Self.isAllowed(url) || url.scheme == "about" || navigationAction.navigationType != .linkActivated {
            decisionHandler(.allow)
        } else {
            if url.scheme == "https" { NSWorkspace.shared.open(url) }
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        errorMessage = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        show(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        show(error)
    }

    /// Отмена загрузки (новая навигация вытеснила старую) — не обрыв связи.
    private func show(_ error: any Error) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
        if nsError.domain == "WebKitErrorDomain", nsError.code == 102 { return }
        errorMessage = "Нет соединения с YouTube Music"
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // Ссылки target=_blank и всплывающие окна входа открываем в том же плеере.
        if let url = navigationAction.request.url {
            if Self.isAllowed(url) {
                webView.load(URLRequest(url: url))
            } else if url.scheme == "https" {
                NSWorkspace.shared.open(url)
            }
        }
        return nil
    }
}
