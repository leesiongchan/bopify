#if DEBUG
import SwiftUI
import Observation
import BopifyDomain
import BopifyPlayback

// Original vector samples for native previews; never used for missing live artwork.
nonisolated func previewArtworkURL(_ index: Int) -> URL { URL(string: "https://preview.invalid/sample/\(index)")! }

func makePreviewArtworkStore() -> ArtworkStore {
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

/// Invented tracks over the three sample covers, so nothing previewed is a real recording.
nonisolated let previewTracks: [Track] = [
    ("Glass Horizon", "Mira Vale", 214_000), ("Night Bloom", "The Lanterns", 187_000), ("Paper Moons", "Odile", 242_000),
    ("Slow Tide", "Mira Vale", 201_000), ("Neon Orchard", "Kestrel", 176_000), ("Quiet Engines", "The Lanterns", 233_000),
    ("Low Sun", "Odile", 195_000), ("Fold & Drift", "Kestrel", 222_000),
].enumerated().map { index, sample in
    Track(uri: SpotifyURI("spotify:track:preview\(index)")!, title: sample.0, artists: [ArtistSummary(name: sample.1)],
          albumTitle: "Preview", artwork: Artwork(url: previewArtworkURL(index % 3)), durationMs: sample.2)
}

enum PreviewScenario {
    case playing, paused, loading, playbackError, mirroring, nothingPlaying
}

/// What the library services answer: sample tracks and stations, nothing, or one error for every request.
enum PreviewLibrary {
    case samples, empty, failing(LibraryError)
}

/// An environment whose player runs `scenario` on the preview engine, with library services that never touch the network.
func makePreviewEnvironment(_ scenario: PreviewScenario = .playing, library: PreviewLibrary = .samples) -> AppEnvironment {
    let engine = PreviewPlaybackEngine(tracks: Array(previewTracks.prefix(5)))
    let player = PlayerModel(engine: engine)
    let events: [PlaybackEvent] = switch scenario {
    case .playing: engine.restoredSession(at: 1, positionMs: 64_000, playing: true)
    case .paused: engine.restoredSession(at: 1, positionMs: 64_000, playing: false)
    case .loading: engine.restoredSession(at: 1, positionMs: 0, playing: false) + [.loading]
    case .playbackError: engine.restoredSession(at: 1, positionMs: 64_000, playing: false) + [.failed(.networkUnavailable)]
    case .mirroring:
        [.startupResolved(.remote(deviceName: "Kitchen Speaker")),
         .remotePlayback(RemotePlayback(deviceName: "Kitchen Speaker", trackURI: previewTracks[2].uri, track: previewTracks[2],
                                        isPlaying: true, positionMs: 98_000, durationMs: previewTracks[2].durationMs))]
    case .nothingPlaying: [.startupResolved(.nothing)]
    }
    player.applyPreviewEvents(events)
    // Commands from the canvas still arrive through the engine's stream.
    player.start()
    let services = PreviewLibraryServices(library)
    return AppEnvironment(previewPlayer: player, favoriteService: services, savedTracksService: services, historyService: services,
                          artworkStore: makePreviewArtworkStore(), radioEngine: engine)
}

/// The player as the window shows it once revealed, in a fixed frame of that mode's layout.
func previewRecordPlayer(_ scenario: PreviewScenario, mode: PlayerMode = .expanded) -> some View {
    let environment = makePreviewEnvironment(scenario)
    let presentation = PlayerPresentation(mode: .compact)
    if mode != .compact {
        // Keyboard focus holds the reveal, as when the window is key.
        presentation.sendAttention(.visibility(true))
        presentation.sendAttention(.keyboardFocus(true))
        presentation.requestQueue(mode == .queue)
    }
    let controller = PlayerWindowController(previewMode: mode)
    return RecordPlayerView(player: environment.player!, artworkStore: environment.artworkStore,
                            presentation: presentation, windowController: controller)
        .environment(environment)
        // PlayerRootView fetches the heart's state in the app.
        .task { await environment.refreshFavorite() }
        .frame(width: controller.layout.contentSize.width, height: controller.layout.contentSize.height)
}

private nonisolated struct PreviewLibraryServices: LibraryService, SavedTracksService, ListeningHistoryService {
    let library: PreviewLibrary
    init(_ library: PreviewLibrary) { self.library = library }

    private func answer<T: Sendable>(_ samples: T, empty: T) throws -> T {
        switch library {
        case .samples: samples
        case .empty: empty
        case let .failing(error): throw error
        }
    }

    func savedState(for uri: SpotifyURI) async throws -> Bool { try answer(uri == previewTracks[1].uri, empty: false) }
    func save(_ uri: SpotifyURI) async throws {}
    func remove(_ uri: SpotifyURI) async throws {}

    func savedTracks(offset: Int, limit: Int) async throws -> SavedTracksPage {
        let page = Array(previewTracks.dropFirst(offset).prefix(limit))
        return try answer(SavedTracksPage(tracks: page, nextOffset: nil, total: previewTracks.count),
                          empty: SavedTracksPage(tracks: [], nextOffset: nil, total: 0))
    }

    func recentlyPlayed() async throws -> [RecentPlay] {
        try answer(previewTracks.reversed().map { RecentPlay(track: $0, contextURI: SpotifyURI("spotify:playlist:preview-recents")) }, empty: [])
    }

    func topItems(_ kind: TopItemKind) async throws -> [StationSeed] {
        let seeds = switch kind {
        case .tracks: previewTracks.prefix(3).map { StationSeed(uri: $0.uri, name: $0.title) }
        case .artists: ["Mira Vale", "The Lanterns", "Odile"].map { StationSeed(uri: SpotifyURI("spotify:artist:\($0.filter(\.isLetter))")!, name: $0) }
        }
        return try answer(seeds, empty: [])
    }
}
@MainActor @Observable final class RecordPreviewFixture {
    let artworkStore = makePreviewArtworkStore()
    var index = 1
    var occurrenceID = "first"
    var direction: CarouselDirection = .next
    var isPlaying = true
    var isVisible = true
    var isArtworkMissing = false
    var reduceMotion = false
    var diameter: CGFloat = 182
    var image: Image? {
        isArtworkMissing ? nil : artworkStore.images[previewArtworkURL(index)].map { Image(nsImage: $0) }
    }
}

struct RecordPreviewScene: View {
    let fixture: RecordPreviewFixture
    @State private var rotation = RecordRotation()
    @State private var isCoasting = false
    @State private var pressing = PressingAppearance.neutral
    private var motorRequest: RecordMotorRequest {
        !fixture.isVisible || fixture.reduceMotion ? .snap : fixture.isPlaying ? .drive : .brake
    }
    var body: some View {
        VinylRecordView(image: fixture.image, occurrenceID: fixture.occurrenceID, direction: fixture.direction,
                        diameter: fixture.diameter,
                        isMoving: motorRequest != .snap && (fixture.isPlaying || isCoasting) && rotation.isMoving(at: ProcessInfo.processInfo.systemUptime),
                        isVisible: fixture.isVisible, rotation: rotation,
                        pressingSeed: pressing.seed, palette: pressing.palette,
                        reduceMotionOverride: fixture.reduceMotion)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: motorRequest, initial: true) { _, request in
                let now = ProcessInfo.processInfo.systemUptime
                rotation.setRunning(request == .drive, at: now, stopStyle: request == .snap ? .snap : .brake)
                isCoasting = request == .brake && rotation.isMoving(at: now)
            }
            .task(id: rotation.stopTime) {
                guard isCoasting, let deadline = rotation.stopTime else { return }
                do { try await Task.sleep(for: .seconds(max(0, deadline - ProcessInfo.processInfo.systemUptime))) }
                catch { return }
                guard rotation.stopTime == deadline else { return }
                isCoasting = false
            }
            .onDisappear {
                rotation.setRunning(false, at: ProcessInfo.processInfo.systemUptime, stopStyle: .snap)
                isCoasting = false
            }
            .task(id: fixture.isArtworkMissing ? -1 : fixture.index) {
                let index = fixture.index
                let seed = PressingSeed.offset(previewTracks[index].uri.rawValue)
                if fixture.isArtworkMissing {
                    pressing = PressingAppearance(seed: seed, palette: .neutral)
                    return
                }
                let url = previewArtworkURL(index)
                await fixture.artworkStore.loadPalette(url)
                guard !Task.isCancelled, index == fixture.index else { return }
                pressing = PressingAppearance(seed: seed,
                                              palette: fixture.artworkStore.palettes[url] ?? .neutral)
            }
    }
}

#Preview("Vinyl record") { RecordPreviewScene(fixture: RecordPreviewFixture()).frame(width: 264, height: 264) }
#endif
