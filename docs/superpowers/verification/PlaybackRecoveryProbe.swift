import AppKit
import SwiftUI
import BopifyAuth
import BopifyDomain
import BopifyPlayback
import BopifyLibrary

@main struct PlaybackRecoveryProbe {
    nonisolated static let uri = SpotifyURI("spotify:track:6rqhFgbbKwnb9MLmUQDhG6")!
    nonisolated static var track: Track { Track(uri: uri, title: "Recovery test", artists: [ArtistSummary(name: "Bopify")], albumTitle: nil, artwork: nil, durationMs: 240_000) }
    @MainActor static func settle() async { for _ in 0..<300 { await Task.yield() } }
    @MainActor static func main() async {
        let store = ProbeTokenStore(), libraryStore = ProbeTokenStore()
        let saved = TokenSet(accessToken: "PLAYBACK_FAKE", refreshToken: "RT_FAKE", expiresAt: .distantFuture, grantedScopes: ["streaming"])
        try! store.save(saved); try! libraryStore.save(saved)
        let opened = ProbeBrowser(), factory = ProbeFactory(), library = ProbeLibrary()
        let player = PlayerModel()
        let environment = AppEnvironment(previewPlayer: player, favoriteService: library, savedTracksService: library, historyService: library,
            playbackAuth: SpotifyAuthService(clientID: "probe", store: store, openURL: { _ in opened.record() }),
            libraryAuth: SpotifyAuthService(clientID: "probe", store: libraryStore),
            recoveryEngineFactory: { token, options in try await factory.create(token, options) })
        await environment.restoreOrPromptSignIn(); await factory.waitForCount(1)
        precondition(environment.authState == .signedIn && environment.player === player)
        let first = ProbeEngine(); factory.release(first); await settle(); first.ready(); await settle()
        await environment.likedSongs.reveal(at: Date())
        first.emit(.volumeChanged(volume: 0)); first.emit(.shuffleChanged(true)); first.emit(.repeatChanged(.context)); await settle()
        let contents = environment.likedSongs.tracks
        let mode = environment.presentation.mode
        first.emit(.sessionLost(.spircEnded)); await factory.waitForCount(2)
        precondition(first.shutdownCount == 1)
        precondition(factory.options[1].snapshot?.shouldResume == true)
        precondition(factory.options[1].snapshot?.volume == 0)
        precondition(factory.options[1].snapshot?.shuffleEnabled == true)
        precondition(environment.player === player && environment.presentation.mode == mode)
        precondition(environment.likedSongs.tracks == contents && libraryStore.load() == saved)
        let second = ProbeEngine(); factory.release(second); await settle(); second.ready(); await settle()
        precondition(environment.connectionStatus == .ready && player.isEngineReady)
        precondition(factory.options[0].deviceID == factory.options[1].deviceID)
        await environment.explore.reveal(at: Date())
        precondition(second.recordedCommands == ["radio"] && first.recordedCommands.isEmpty)
        precondition(opened.count == 0)
        // Sign-out rejects a blocking create before its serialized cleanup starts.
        second.emit(.sessionLost(.spircEnded)); await factory.waitForCount(3)
        let signOut = Task { await environment.signOut() }; await settle()
        let late = ProbeEngine(); factory.release(late); await signOut.value
        precondition(late.shutdownCount == 1 && environment.player == nil)
        precondition(store.load() == nil && libraryStore.load() == nil)
        await checkQuitAndInitialNetworkFailure()
        print("PASS: stable player/library, serialized replacement, stable device ID, late-create sign-out, no unsolicited browser")
    }
    @MainActor static func checkQuitAndInitialNetworkFailure() async {
        let store = ProbeTokenStore(), opened = ProbeBrowser(), factory = ProbeFactory()
        let saved = TokenSet(accessToken: "SAVED_FAKE", refreshToken: "RT_FAKE", expiresAt: .distantFuture, grantedScopes: ["streaming"])
        try! store.save(saved)
        let environment = AppEnvironment(previewPlayer: PlayerModel(), favoriteService: ProbeLibrary(), playbackAuth: SpotifyAuthService(clientID: "probe", store: store, openURL: { _ in opened.record() }), recoveryEngineFactory: { token, options in try await factory.create(token, options) })
        await environment.restoreOrPromptSignIn(); await factory.waitForCount(1)
        factory.fail(.networkUnavailable); await settle()
        precondition(environment.authState == .signedIn && environment.connectionStatus == .reconnecting && opened.count == 0)
        environment.retryPlaybackConnection(); await factory.waitForCount(2)
        precondition(factory.options[1].startup == .coldLaunch)
        let quitting = Task { await environment.prepareForQuit() }; await settle()
        let late = ProbeEngine(); factory.release(late); await quitting.value
        precondition(late.shutdownCount == 1 && environment.player == nil && store.load() == saved)
        // A pending browser authorization must not block quit or erase the previous grant.
        let auth = SpotifyAuthService(clientID: "probe", store: store, openURL: { _ in opened.record() })
        let consenting = AppEnvironment(previewPlayer: PlayerModel(), favoriteService: ProbeLibrary(), playbackAuth: auth)
        let signIn = Task { await consenting.signIn() }
        while opened.count == 0 { await Task.yield() }
        await consenting.prepareForQuit(); await signIn.value
        precondition(consenting.player == nil && store.load() == saved)
        print("PASS: initial network retry uses cold launch, late-create quit, pending OAuth quit preserves grant")
    }

}

nonisolated final class ProbeTokenStore: TokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: TokenSet?
    nonisolated func load() -> TokenSet? { lock.withLock { tokens } }
    nonisolated func save(_ value: TokenSet) throws { lock.withLock { tokens = value } }
    nonisolated func clear() throws { lock.withLock { tokens = nil } }
}
nonisolated final class ProbeBrowser: @unchecked Sendable {
    private let lock = NSLock()
    private var opens = 0
    nonisolated var count: Int { lock.withLock { opens } }
    nonisolated func record() { lock.withLock { opens += 1 } }
}
@MainActor final class ProbeFactory {
    var options: [PlaybackEngineConfiguration] = []
    private var pending: CheckedContinuation<any ManagedPlaybackEngine, any Error>?
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    func create(_ token: String, _ options: PlaybackEngineConfiguration) async throws -> any ManagedPlaybackEngine {
        self.options.append(options)
        return try await withCheckedThrowingContinuation { pending = $0
            for (count, waiter) in waiters where self.options.count >= count { waiter.resume() }
            waiters.removeAll { self.options.count >= $0.0 }
        }
    }
    func waitForCount(_ count: Int) async { if options.count >= count { return }; await withCheckedContinuation { waiters.append((count, $0)) } }
    func release(_ engine: ProbeEngine) { pending?.resume(returning: engine); pending = nil }
    func fail(_ error: PlayerError) { pending?.resume(throwing: error); pending = nil }
}
nonisolated final class ProbeEngine: ManagedPlaybackEngine, @unchecked Sendable {
    nonisolated let events: AsyncStream<PlaybackEvent>
    nonisolated private let continuation: AsyncStream<PlaybackEvent>.Continuation
    private let lock = NSLock()
    private var shutdowns = 0
    private var commands: [String] = []
    nonisolated var shutdownCount: Int { lock.withLock { shutdowns } }
    nonisolated var recordedCommands: [String] { lock.withLock { commands } }
    nonisolated init() { (events, continuation) = AsyncStream.makeStream() }
    nonisolated func emit(_ event: PlaybackEvent) { continuation.yield(event) }
    nonisolated func ready() {
        emit(.trackChanged(PlaybackRecoveryProbe.track)); emit(.recoveryIdentity(PlaybackIdentity(trackURI: PlaybackRecoveryProbe.uri)))
        emit(.playing(positionMs: 12_000)); emit(.connectionReady(.local(PlaybackIdentity(trackURI: PlaybackRecoveryProbe.uri))))
    }
    nonisolated func shutdown() async { lock.withLock { shutdowns += 1 }; continuation.finish() }
    nonisolated func record(_ name: String) { lock.withLock { commands.append(name) } }
    nonisolated func load(_ request: PlayRequest) async throws { record("load") }
    nonisolated func resume() async throws { record("resume") }
    nonisolated func playHere() async throws { record("playHere") }
    nonisolated func pause() async throws { record("pause") }
    nonisolated func next() async throws { record("next") }
    nonisolated func previous() async throws { record("previous") }
    nonisolated func seek(to milliseconds: Int64) async throws { record("seek") }
    nonisolated func setVolume(_ value: Double) async throws { record("volume") }
    nonisolated func selectQueueEntry(_ target: QueueTarget) async throws { record("queue") }
    nonisolated func setShuffle(_ enabled: Bool) async throws { record("shuffle") }
    nonisolated func setRepeat(_ mode: RepeatMode) async throws { record("repeat") }
    nonisolated func requestRadio(seed: SpotifyURI) async throws -> RadioMix { record("radio"); return RadioMix(contextURI: seed, tracks: [PlaybackRecoveryProbe.track]) }
}
actor ProbeLibrary: LibraryService, SavedTracksService, ListeningHistoryService {
    func recentlyPlayed() async throws -> [RecentPlay] { [] }
    func topItems(_ kind: TopItemKind) async throws -> [StationSeed] { [StationSeed(uri: PlaybackRecoveryProbe.uri, name: "Probe station")] }
    func savedState(for uri: SpotifyURI) async throws -> Bool { false }
    func save(_ uri: SpotifyURI) async throws {}
    func remove(_ uri: SpotifyURI) async throws {}
    func savedTracks(offset: Int, limit: Int) async throws -> SavedTracksPage { SavedTracksPage(tracks: [PlaybackRecoveryProbe.track], nextOffset: nil, total: 1) }
}
