import Foundation
import BopifyDomain
import BopifyPlayback

final class RecoveryStubEngine: ManagedPlaybackEngine, @unchecked Sendable {
    let events: AsyncStream<PlaybackEvent>
    private let continuation: AsyncStream<PlaybackEvent>.Continuation
    private let lock = NSLock()
    private var commands: [String] = []
    private var shutdowns = 0
    var commandError: PlayerError?
    var shutdownGate: (@Sendable () async -> Void)?
    var commandGate: (@Sendable () async -> Void)?
    var recordedCommands: [String] { lock.withLock { commands } }
    var shutdownCount: Int { lock.withLock { shutdowns } }
    init() { (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded) }
    func emit(_ event: PlaybackEvent) { continuation.yield(event) }
    func finishEvents() { continuation.finish() }
    func shutdown() async { lock.withLock { shutdowns += 1 }; continuation.finish(); await shutdownGate?() }
    private func record(_ value: String) async throws {
        lock.withLock { commands.append(value) }
        await commandGate?()
        if let commandError { throw commandError }
    }
    func load(_ request: PlayRequest) async throws { try await record("load") }
    func resume() async throws { try await record("resume") }
    func playHere() async throws { try await record("playHere") }
    func pause() async throws { try await record("pause") }
    func next() async throws { try await record("next") }
    func previous() async throws { try await record("previous") }
    func seek(to milliseconds: Int64) async throws { try await record("seek") }
    func setVolume(_ value: Double) async throws { try await record("volume") }
    func selectQueueEntry(_ target: QueueTarget) async throws { try await record("selectQueue") }
    func setShuffle(_ enabled: Bool) async throws { try await record("shuffle") }
    func setRepeat(_ mode: RepeatMode) async throws { try await record("repeat") }
    func requestRadio(seed: SpotifyURI) async throws -> RadioMix { try await record("radio"); throw RadioFailure.unavailable }
    func requestLyrics(for track: SpotifyURI) async throws -> TrackLyrics { try await record("lyrics"); throw LyricFailure.unavailable }
    func requestArtistTopTracks(for track: SpotifyURI, artistIndex: Int) async throws -> ArtistTopTracks { try await record("artistTopTracks"); throw ArtistTopTracksFailure.unavailable }
}
