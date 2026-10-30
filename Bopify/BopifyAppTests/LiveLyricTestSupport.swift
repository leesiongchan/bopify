import Foundation
import Testing
import BopifyDomain
import BopifyPlayback

@MainActor final class LiveLyricRequestGate {
    struct Request { let id: Int; let uri: SpotifyURI; let epoch: UInt64? }
    private(set) var requests: [Request] = []
    private(set) var cancelled: Set<Int> = []
    private var waiting: [Int: CheckedContinuation<TrackLyrics, any Error>] = [:]

    func request(for uri: SpotifyURI, epoch: UInt64?) async throws -> TrackLyrics {
        let id = requests.count
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                requests.append(Request(id: id, uri: uri, epoch: epoch))
                waiting[id] = continuation
                if Task.isCancelled { cancelled.insert(id) }
            }
        } onCancel: { Task { @MainActor in self.cancelled.insert(id) } }
    }
    func succeed(_ id: Int, with lyrics: TrackLyrics) { waiting.removeValue(forKey: id)?.resume(returning: lyrics) }
    func fail(_ id: Int, with error: any Error) { waiting.removeValue(forKey: id)?.resume(throwing: error) }
    func finish() {
        let pending = waiting.values
        waiting = [:]
        for continuation in pending { continuation.resume(throwing: CancellationError()) }
    }
}

@MainActor final class LiveLyricTestEngine: ManagedPlaybackEngine {
    nonisolated let events: AsyncStream<PlaybackEvent>
    private let continuation: AsyncStream<PlaybackEvent>.Continuation
    private(set) var commands: [String] = []
    private(set) var loadRequests: [PlayRequest] = []
    private(set) var seekTargets: [Int64] = []
    private(set) var shutdowns = 0
    var shutdownGate: (@MainActor () async -> Void)?
    private let lyricRequest: @MainActor (SpotifyURI) async throws -> TrackLyrics
    init(lyricRequest: @escaping @MainActor (SpotifyURI) async throws -> TrackLyrics = { _ in throw LyricFailure.unavailable }) {
        (events, continuation) = AsyncStream.makeStream()
        self.lyricRequest = lyricRequest
    }
    func emit(_ event: PlaybackEvent) { continuation.yield(event) }
    func shutdown() async { shutdowns += 1; continuation.finish(); await shutdownGate?() }
    func load(_ request: PlayRequest) async throws { commands.append("load"); loadRequests.append(request) }
    func resume() async throws { commands.append("resume") }
    func playHere() async throws { commands.append("playHere") }
    func pause() async throws { commands.append("pause") }
    func next() async throws { commands.append("next") }
    func previous() async throws { commands.append("previous") }
    func seek(to milliseconds: Int64) async throws { commands.append("seek"); seekTargets.append(milliseconds) }
    func setVolume(_ value: Double) async throws { commands.append("volume") }
    func selectQueueEntry(_ target: QueueTarget) async throws { commands.append("queue") }
    func setShuffle(_ enabled: Bool) async throws { commands.append("shuffle") }
    func setRepeat(_ mode: RepeatMode) async throws { commands.append("repeat") }
    func requestRadio(seed: SpotifyURI) async throws -> RadioMix { throw RadioFailure.unavailable }
    func requestLyrics(for track: SpotifyURI) async throws -> TrackLyrics { try await lyricRequest(track) }
    func requestArtistTopTracks(for track: SpotifyURI, artistIndex: Int) async throws -> ArtistTopTracks { throw ArtistTopTracksFailure.unavailable }
}

@MainActor final class LiveLyricTestClock {
    var now = Date.now
    private var waiting: [UUID: (Date, Duration, CheckedContinuation<Void, any Error>)] = [:]
    var pendingDelays: [Duration] { waiting.values.map { $0.1 } }
    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                waiting[id] = (now.addingTimeInterval(seconds(duration)), duration, continuation)
            }
        } onCancel: { Task { @MainActor in self.waiting.removeValue(forKey: id)?.2.resume(throwing: CancellationError()) } }
    }
    func advance(by duration: Duration) {
        now += seconds(duration)
        for id in waiting.filter({ $0.value.0 <= now }).keys { waiting.removeValue(forKey: id)?.2.resume() }
    }
    private func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

@MainActor func liveLyricEventually(_ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !condition(), ContinuousClock.now < deadline { await Task.yield() }
    try #require(condition(), "Live lyric state did not settle")
}

nonisolated let liveLyricURI = SpotifyURI("spotify:track:11dFghVXANMlKmJXsNCbNl")!
nonisolated let otherLiveLyricURI = SpotifyURI("spotify:track:4uLU6hMCjMI75M1A2tKUQC")!
nonisolated func liveLyricTrack(_ uri: SpotifyURI = liveLyricURI) -> Track {
    Track(uri: uri, title: "Window Seat", artists: [ArtistSummary(name: "Soft Weather")],
          albumTitle: nil, artwork: nil, durationMs: 240_000)
}
nonisolated func liveLyricQueue(_ uri: SpotifyURI = liveLyricURI, id: String = "one") -> PlaybackQueue {
    PlaybackQueue(generation: 1, previous: [], current: QueueEntry(id: id, uri: uri, target: nil,
        track: liveLyricTrack(uri), metadataFailed: false), next: [])
}
nonisolated func liveLyrics(_ uri: SpotifyURI = liveLyricURI, displayName: String = "Fixture provider") -> TrackLyrics {
    TrackLyrics(trackURI: uri, synchronization: .lineSynced,
        lines: [TrackLyricLine(text: "A quiet street", startTimeMs: 1000), TrackLyricLine(text: "The lamps return", startTimeMs: 2000)],
        provider: "fixture", providerDisplayName: displayName, isRightToLeft: false)
}
