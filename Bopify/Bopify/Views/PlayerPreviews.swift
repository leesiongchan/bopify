#if DEBUG
import SwiftUI
import BopifyDomain
import BopifyPlayback

#Preview("Playing · dark") {
    PlayerPreview(phase: .playing).environment(\.colorScheme, .dark)
}

#Preview("Long title · light") {
    PlayerPreview(phase: .paused, longTitle: true).environment(\.colorScheme, .light)
}

#Preview("Loading · missing artwork") {
    PlayerPreview(phase: .loading, missingArtwork: true)
}

#Preview("Playback error") {
    PlayerPreview(phase: .error(.networkUnavailable))
}

#Preview("Ready to play") {
    PlayerPreview(phase: .idle, missingArtwork: true)
}

private struct PlayerPreview: View {
    let phase: PlaybackPhase
    var longTitle = false
    var missingArtwork = false
    @State private var player = PlayerModel(engine: StubPlaybackEngine())

    private var artwork: Image? {
        guard !missingArtwork else { return nil }
        let renderer = ImageRenderer(content:
            ZStack {
                LinearGradient(colors: [.indigo, .pink, .orange], startPoint: .topLeading, endPoint: .bottomTrailing)
                ForEach(0..<5) { index in
                    Ellipse().stroke(.white.opacity(0.45), lineWidth: 2)
                        .frame(width: 90 + CGFloat(index) * 26, height: 220)
                        .rotationEffect(.degrees(-35))
                }
            }
            .frame(width: 240, height: 240)
            .clipped()
        )
        return renderer.nsImage.map { Image(nsImage: $0) }
    }

    var body: some View {
        PlayerSurface(palette: ArtworkPalette(primary: .purple, secondary: .orange)) {
            VStack(spacing: 12) {
                HStack {
                    Label("app.name", systemImage: "waveform")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.7))
                    Spacer()
                    Image(systemName: "ellipsis")
                }
                .frame(height: 24)
                PlayingView(player: player, image: artwork, state: state, position: { _ in 83_000 })
            }
            .padding(24)
        }
        .frame(width: 410, height: 560)
    }

    private var state: PlaybackState {
        var state = PlaybackState()
        state.phase = phase
        guard phase != .idle else { return state }
        state.currentTrack = Track(
            uri: SpotifyURI("spotify:track:preview")!,
            title: longTitle ? "A Very Long Track Title That Should Never Cover the Controls" : "Afterglow",
            artists: [ArtistSummary(name: longTitle ? "An Artist with an Equally Long Name" : "The Evening Hours")],
            albumTitle: nil, artwork: nil, durationMs: 238_000)
        state.durationMs = 238_000
        state.positionMs = 83_000
        state.isActiveDevice = true
        state.canPrevious = true
        state.canNext = true
        return state
    }
}
#endif
