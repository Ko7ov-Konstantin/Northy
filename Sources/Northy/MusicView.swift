import SwiftUI
import WebKit

struct MusicView: View {
    @State private var player = MusicPlayer()

    var body: some View {
        VStack(spacing: 8) {
            NowPlayingBar(player: player)
            MusicWebView(webView: player.webView)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.edge, lineWidth: 1) }
                .overlay {
                    if let message = player.errorMessage {
                        VStack(spacing: 8) {
                            Text(message)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.secondaryText)
                            Button("Обновить") { player.reload() }
                        }
                        .padding(16)
                        .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
        }
        .task {
            while !Task.isCancelled {
                await player.refreshState()
                try? await Task.sleep(for: .milliseconds(1500))
            }
        }
    }
}

private struct MusicWebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

private struct NowPlayingBar: View {
    var player: MusicPlayer

    var body: some View {
        HStack(spacing: 10) {
            artwork
            VStack(alignment: .leading, spacing: 2) {
                Text(player.state?.title ?? "Ничего не играет")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(player.state == nil ? Theme.secondaryText : Theme.primaryText)
                    .lineLimit(1)
                if let artist = player.state?.artist, !artist.isEmpty {
                    Text(artist)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
                ProgressBar(value: player.state?.progress ?? 0)
                    .frame(height: 3)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            IconButton(systemName: "backward.fill", help: "Предыдущий") { player.send(.previous) }
            IconButton(
                systemName: player.state?.isPlaying == true ? "pause.fill" : "play.fill",
                tint: PanelTab.music.tint,
                size: 32,
                help: "Пауза / воспроизведение"
            ) { player.send(.playPause) }
            IconButton(systemName: "forward.fill", help: "Следующий") { player.send(.next) }
        }
        .padding(.horizontal, 4)
        .frame(height: 44)
    }

    private var artwork: some View {
        AsyncImage(url: player.state?.artworkURL) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Image(systemName: "music.note")
                .foregroundStyle(Theme.tertiaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.card)
        }
        .frame(width: 40, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct ProgressBar: View {
    var value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule().fill(PanelTab.music.tint).frame(width: geo.size.width * value)
            }
        }
    }
}
