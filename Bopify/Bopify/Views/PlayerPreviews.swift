#if DEBUG
import SwiftUI
import BopifyDomain
import BopifyPlayback

#Preview("Abstract sample · dark") {
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

#Preview("Compact · long metadata") {
    PlayerPreview(phase: .playing, longTitle: true, mode: .compact)
}

#Preview("Up Next · 80 repeated songs") {
    PlayerPreview(phase: .playing, mode: .queue, queueCount: 80)
}

#Preview("Up Next · empty") {
    PlayerPreview(phase: .paused, mode: .queue, queueCount: 0)
}

private struct PlayerPreview: View {
    let phase: PlaybackPhase
    var longTitle = false
    var missingArtwork = false
    var queueCount = 1
    @Namespace private var artworkNamespace
    @State private var presentation: PlayerPresentation
    @State private var store = previewArtworkStore()
    @State private var player = PlayerModel(engine: StubPlaybackEngine())

    init(phase: PlaybackPhase, longTitle: Bool = false, missingArtwork: Bool = false,
         mode: PlayerMode = .expanded, queueCount: Int = 1) {
        self.phase = phase
        self.longTitle = longTitle
        self.missingArtwork = missingArtwork
        self.queueCount = queueCount
        _presentation = State(initialValue: PlayerPresentation(mode: mode))
    }

    private var artwork: Image? {
        guard !missingArtwork else { return nil }
        return store.images[previewArtworkURL(1)].map { Image(nsImage: $0) }
    }

    var body: some View {
        PlayerSurface(palette: ArtworkPalette(primary: .purple, secondary: .orange)) {
            if presentation.mode == .compact {
                CompactPlayerView(player: player, state: state, store: store, presentation: presentation, artworkNamespace: artworkNamespace).padding(8)
            } else {
                VStack(spacing: 8) {
                    HStack {
                        Text(presentation.mode == .queue ? "queue.title" : "app.name")
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "ellipsis")
                    }
                    .frame(height: 24)
                    if presentation.mode == .queue {
                        QueueView(player: player, state: state, store: store, presentation: presentation, artworkNamespace: artworkNamespace)
                    } else {
                        PlayingView(player: player, image: artwork, state: state, position: { _ in 83_000 },
                                    store: store, presentation: presentation, artworkNamespace: artworkNamespace)
                    }
                }
                .padding(16)
            }
        }
        .frame(width: presentation.mode == .compact ? 380 : 410, height: presentation.mode == .compact ? 88 : 560)
        .animation(.spring(duration: 0.55, bounce: 0.04), value: presentation.mode)
    }

    private var state: PlaybackState {
        var state = PlaybackState()
        state.phase = phase
        guard phase != .idle else { return state }
        state.currentTrack = Track(
            uri: SpotifyURI("spotify:track:preview")!,
            title: longTitle ? "A Very Long Track Title That Should Never Cover the Controls" : "Afterglow",
            artists: [ArtistSummary(name: longTitle ? "An Artist with an Equally Long Name" : "The Evening Hours")],
            albumTitle: nil, artwork: missingArtwork ? nil : Artwork(url: previewArtworkURL(1)), durationMs: 238_000)
        let previous = Track(uri: SpotifyURI("spotify:track:previous")!, title: "Morning Light", artists: [ArtistSummary(name: "The Quiet Coast")], albumTitle: nil,
                             artwork: missingArtwork ? nil : Artwork(url: previewArtworkURL(0)), durationMs: 205_000)
        let next = Track(uri: SpotifyURI("spotify:track:next")!, title: "Slow Bloom", artists: [ArtistSummary(name: "Garden Radio")], albumTitle: nil,
                         artwork: missingArtwork ? nil : Artwork(url: previewArtworkURL(2)), durationMs: 191_000)
        state.queue = PlaybackQueue(generation: 1,
            previous: [QueueEntry(id: "previous", uri: previous.uri, target: nil, track: previous, metadataFailed: false)],
            current: QueueEntry(id: "current", uri: state.currentTrack!.uri, target: nil, track: state.currentTrack, metadataFailed: false),
            next: (0..<queueCount).map { QueueEntry(id: "next-\($0)", uri: next.uri, target: QueueTarget(generation: 1, rawNextIndex: UInt32($0)), track: next, metadataFailed: false) })
        state.canSeek = true
        state.durationMs = 238_000
        state.positionMs = 83_000
        state.isActiveDevice = true
        state.canPrevious = true
        state.canNext = true
        return state
    }
}
// Original vector samples for native previews; never used for missing live artwork.
private func previewArtworkURL(_ index: Int) -> URL { URL(string: "https://preview.invalid/sample/\(index)")! }

private func previewArtworkStore() -> ArtworkStore {
    var images: [URL: NSImage] = [:]
    for index in 0..<3 {
        let colors: [Color] = switch index {
        case 0: [.cyan, .teal, .black]
        case 1: [.indigo, .pink, .orange]
        default: [Color(red: 0.9, green: 0.79, blue: 0.65), .orange, .brown]
        }
        let renderer = ImageRenderer(content: ZStack {
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            if index == 2 {
                ForEach(0..<8) { petal in
                    Ellipse().fill(.pink.opacity(0.7)).frame(width: 72, height: 130)
                        .offset(y: -35).rotationEffect(.degrees(Double(petal) * 45))
                }
                Circle().fill(.yellow.opacity(0.9)).frame(width: 45, height: 45)
            } else {
                ForEach(0..<5) { line in
                    Ellipse().stroke(.white.opacity(0.45), lineWidth: 2)
                        .frame(width: 90 + CGFloat(line) * 26, height: 220)
                        .rotationEffect(.degrees(index == 0 ? 35 : -35))
                }
            }
        }.frame(width: 240, height: 240).clipped())
        if let image = renderer.nsImage { images[previewArtworkURL(index)] = image }
    }
    return ArtworkStore(previewImages: images)
}
#endif
