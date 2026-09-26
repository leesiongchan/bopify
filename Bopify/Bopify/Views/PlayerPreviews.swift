#if DEBUG
import SwiftUI
import Observation
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

#Preview("Startup · loading") {
    PlayerPreview(phase: .idle, missingArtwork: true)
}

#Preview("Startup · playing on another device") {
    PlayerPreview(phase: .idle, missingArtwork: true, startup: .resolved(.remote(deviceName: "iPhone")))
}

#Preview("Last resort · paste a link") {
    PlayerPreview(phase: .idle, missingArtwork: true, startup: .resolved(.nothing))
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


#Preview("Expanded · 390") {
    PlayerPreview(phase: .playing, width: 390)
}
#Preview("Expanded · 430") {
    PlayerPreview(phase: .playing, width: 430)
}
#Preview("Compact · 340") {
    PlayerPreview(phase: .paused, longTitle: true, mode: .compact, width: 340)
}
#Preview("Compact · 420") {
    PlayerPreview(phase: .paused, longTitle: true, mode: .compact, width: 420)
}
#Preview("Increased text · ended") {
    PlayerPreview(phase: .ended, longTitle: true).environment(\.dynamicTypeSize, .accessibility3)
}

private struct PlayerPreview: View {
    let phase: PlaybackPhase
    var longTitle = false
    var missingArtwork = false
    var queueCount = 1
    var width: CGFloat?
    var startup: StartupPhase = .pending
    @Namespace private var artworkNamespace
    @State private var presentation: PlayerPresentation
    @State private var store = previewArtworkStore()
    @State private var player = PlayerModel(engine: StubPlaybackEngine())

    init(phase: PlaybackPhase, longTitle: Bool = false, missingArtwork: Bool = false,
         mode: PlayerMode = .expanded, queueCount: Int = 1, width: CGFloat? = nil,
         startup: StartupPhase = .pending) {
        self.phase = phase
        self.longTitle = longTitle
        self.missingArtwork = missingArtwork
        self.queueCount = queueCount
        self.width = width
        self.startup = startup
        _presentation = State(initialValue: PlayerPresentation(mode: mode))
    }

    private var artwork: Image? {
        guard !missingArtwork else { return nil }
        return store.images[previewArtworkURL(1)].map { Image(nsImage: $0) }
    }

    var body: some View {
        PlayerSurface {
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
        .modifier(SharedCurrentArtwork(image: artwork, namespace: artworkNamespace))
        .frame(width: width ?? (presentation.mode == .compact ? 380 : 410), height: presentation.mode == .compact ? 88 : 560)
        .animation(.spring(duration: 0.36, bounce: 0.04), value: presentation.mode)
    }

    private var state: PlaybackState {
        var state = PlaybackState()
        state.phase = phase
        state.startup = startup
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
@MainActor @Observable final class PlayerMotionFixture {
    var index = 1
    let presentation = PlayerPresentation()
    let store = previewArtworkStore()
    let player = PlayerModel(engine: StubPlaybackEngine())
    var state: PlaybackState {
        let tracks = (0..<5).map { n in Track(uri: SpotifyURI("spotify:track:sample\(n)")!, title: "Sample \(n)", artists: [ArtistSummary(name: "Native motion fixture")], albumTitle: nil, artwork: Artwork(url: previewArtworkURL(n % 3)), durationMs: 238000) }
        func entry(_ n: Int) -> QueueEntry { QueueEntry(id: "occurrence-\(n)", uri: tracks[n].uri, target: QueueTarget(generation: UInt64(index), rawNextIndex: UInt32(max(0, n-index-1))), track: tracks[n], metadataFailed: false) }
        var value = PlaybackState()
        value.phase = .paused
        value.currentTrack = tracks[index]
        value.durationMs = 238000
        value.positionMs = 83000
        value.isActiveDevice = true
        value.canNext = true
        value.canPrevious = true
        value.canSeek = true
        value.queue = PlaybackQueue(generation: UInt64(index), previous: (0..<index).map(entry), current: entry(index), next: ((index+1)..<5).map(entry))
        return value
    }
}
struct PlayerMotionScene: View {
    let fixture: PlayerMotionFixture
    @Namespace var artwork
    var body: some View {
        let state = fixture.state
        PlayerSurface {
            if fixture.presentation.mode == .compact {
                CompactPlayerView(player: fixture.player, state: state, store: fixture.store, presentation: fixture.presentation, artworkNamespace: artwork).padding(8)
            } else if fixture.presentation.mode == .queue {
                QueueView(player: fixture.player, state: state, store: fixture.store, presentation: fixture.presentation, artworkNamespace: artwork).padding(16)
            } else {
                PlayingView(player: fixture.player, image: state.currentTrack?.artwork.flatMap { fixture.store.images[$0.url] }.map { Image(nsImage: $0) }, state: state, position: { _ in 83000 }, store: fixture.store, presentation: fixture.presentation, artworkNamespace: artwork).padding(16)
            }
        }
        .modifier(SharedCurrentArtwork(image: state.currentTrack?.artwork.flatMap { fixture.store.images[$0.url] }.map { Image(nsImage: $0) }, namespace: artwork))
        .animation(.spring(duration: 0.36, bounce: 0.04), value: fixture.presentation.mode)
    }
}

@MainActor @Observable final class GlassProbeState {
    var seeks: [Int64] = []
    var skips = 0
    var canSeek = true
    var canNext = true
    var occurrence = "current"
    var durationMs: Int64 = 100_000
    var replacementTrack: Track?
}
struct GlassGestureScene: View {
    let state: GlassProbeState
    let fixture: PlayerMotionFixture
    @Namespace private var artwork
    var body: some View {
        let track = state.replacementTrack ?? fixture.state.currentTrack
        ArtworkCarouselView(queue: fixture.state.queue, currentTrack: track,
                            image: track?.artwork.flatMap { fixture.store.images[$0.url] }.map { Image(nsImage: $0) },
                            store: fixture.store, artworkNamespace: artwork,
                            canNext: state.canNext, next: { state.skips += 1 })
            .overlay {
                RadialProgressView(positionMs: 50_000, durationMs: state.durationMs,
                                   canSeek: state.canSeek, seek: { state.seeks.append($0) })
                    .frame(width: 274, height: 274).position(x: 205, y: 165)
                    .id([track?.uri.rawValue, fixture.state.queue?.current?.id, state.occurrence])
            }
            .modifier(SharedCurrentArtwork(image: track?.artwork.flatMap { fixture.store.images[$0.url] }.map { Image(nsImage: $0) }, namespace: artwork))
            .frame(width: 410, height: 340)
    }
}

#endif
