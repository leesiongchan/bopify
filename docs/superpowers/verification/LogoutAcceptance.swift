import Foundation
import BopifyAuth
import BopifyDomain
import BopifyLibrary
import BopifyPlayback

// Headless boundaries prevent windows, system media integration and image requests.
@MainActor final class ArtworkStore {
    var clearCount = 0
    func clear() { clearCount += 1 }
    func retryFailedLoads(connectivityRestored: Bool = false) {}
}
@MainActor final class PlayerWindowController {
    var invalidations = 0
    init(defaults: UserDefaults) {}
    func invalidateTransition() { invalidations += 1 }
}
@MainActor final class LibrarySetupWindowController {
    func show(environment: AppEnvironment) { preconditionFailure("Unexpected GUI") }
    func close() {}
}
@MainActor final class PlaybackConnectionMonitor {
    init(coordinator: PlaybackRecoveryCoordinator, onConnectivityRestored: @escaping @MainActor () -> Void = {}) {}
    func start() { preconditionFailure("Unexpected system connection monitor") }
    func stop() {}
}
@MainActor final class NowPlayingController {
    static var starts = 0, stops = 0
    init(player: PlayerModel, artworkStore: ArtworkStore) { Self.starts += 1 }
    func stop() { Self.stops += 1 }
}

nonisolated final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
nonisolated final class FakeStore: TokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: TokenSet? = TokenSet(accessToken: "SYNTHETIC", refreshToken: "SYNTHETIC_RT", expiresAt: .now.addingTimeInterval(3600), grantedScopes: ["streaming", "user-library-read"])
    private var failure = false, clears = 0, loads = 0
    var failClear: Bool {
        get { lock.withLock { failure } }
        set { lock.withLock { failure = newValue } }
    }
    var clearCount: Int { lock.withLock { clears } }
    var loadCount: Int { lock.withLock { loads } }
    var hasTokens: Bool { lock.withLock { tokens != nil } }
    func save(_ value: TokenSet) { lock.withLock { tokens = value } }
    func load() -> TokenSet? { lock.withLock { loads += 1; return tokens } }
    func clear() throws {
        try lock.withLock {
            clears += 1
            if failure { throw KeychainError.unavailable(-25308) }
            tokens = nil
        }
    }
}
nonisolated struct FakeLibrary: LibraryService, SavedTracksService, ListeningHistoryService {
    let track: Track
    func savedState(for uri: SpotifyURI) async throws -> Bool { true }
    func save(_ uri: SpotifyURI) async throws {}
    func remove(_ uri: SpotifyURI) async throws {}
    func savedTracks(offset: Int, limit: Int) async throws -> SavedTracksPage { SavedTracksPage(tracks: [track], nextOffset: nil, total: 1) }
    func recentlyPlayed() async throws -> [RecentPlay] { [RecentPlay(track: track, contextURI: nil)] }
    func topItems(_ kind: TopItemKind) async throws -> [StationSeed] { [StationSeed(uri: track.uri, name: "Synthetic")] }
}

@main struct LogoutAcceptance {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try await staleReconnect(root)
        try await explicitReconnect()
        for (p, l) in [(false, false), (false, true), (true, false), (true, true)] {
            try await matrix(root, playbackFails: p, libraryFails: l)
        }
        try await startup(root, malformed: false)
        try await startup(root, malformed: true)
        try await unrecorded(root)
        try await quit(root)
        print("PASS: logout and recovery authorization boundaries; no real browser, Keychain calls, windows or external network")
    }
    @MainActor static func checked(_ condition: @autoclosure () throws -> Bool) rethrows {
        let result = try condition()
        precondition(result)
    }
    @MainActor static func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        preconditionFailure("Fixture condition timed out")
    }
    @MainActor static func directory(_ root: URL, _ name: String) throws -> URL {
        let url = root.appendingPathComponent(name + "-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    @MainActor static func make(_ intent: LogoutIntentStore, playback: FakeStore, library: FakeStore,
                                engine: RecoveryStubEngine, browser: Counter, creates: Counter) -> (AppEnvironment, PlayerModel) {
        let player = PlayerModel()
        let track = Track(uri: SpotifyURI("spotify:track:6rqhFgbbKwnb9MLmUQDhG6")!, title: "Synthetic", artists: [], albumTitle: nil, artwork: nil, durationMs: 100000)
        let service = FakeLibrary(track: track)
        let auth = SpotifyAuthService(clientID: "synthetic", store: playback, logoutIntent: intent, openURL: { _ in browser.increment(); preconditionFailure("Unexpected browser") })
        let libraryAuth = SpotifyAuthService(clientID: "synthetic", store: library, logoutIntent: intent, credentialNamespace: .library, openURL: { _ in browser.increment(); preconditionFailure("Unexpected browser") })
        let env = AppEnvironment(previewPlayer: player, favoriteService: service, savedTracksService: service, historyService: service,
                                 playbackAuth: auth, libraryAuth: libraryAuth, logoutIntent: intent,
                                 recoveryEngineFactory: { _, _ in creates.increment(); return engine })
        return (env, player)
    }
    @MainActor static func populate(_ env: AppEnvironment, engine: RecoveryStubEngine) async throws {
        await env.restoreOrPromptSignIn()
        try await wait { env.recovery?.currentEngine != nil }
        engine.emit(.connectionReady(.local(PlaybackIdentity(trackURI: SpotifyURI("spotify:track:6rqhFgbbKwnb9MLmUQDhG6")!))))
        try await wait { env.connectionStatus == .ready }
        let uri = SpotifyURI("spotify:track:6rqhFgbbKwnb9MLmUQDhG6")!
        await env.favorite.select(uri)
        await env.likedSongs.reveal(at: .now)
        await env.recents.reveal(at: .now)
        await env.explore.reveal(at: .now)
        precondition(env.favorite.saved == true && !env.likedSongs.tracks.isEmpty && !env.recents.tracks.isEmpty && !env.explore.chips.isEmpty)
        env.presentation.isVisible = true
        env.presentation.presentPopover(.favorite)
        precondition(env.presentation.activePopover != nil)
    }
    @MainActor static func assertTornDown(_ env: AppEnvironment, player: PlayerModel) {
        precondition(env.player == nil && env.recovery == nil && !player.isEngineReady)
        precondition(env.favorite.uri == nil && env.favorite.saved == nil && !env.favorite.isPending)
        precondition(env.likedSongs.tracks.isEmpty && env.recents.tracks.isEmpty && env.explore.chips.isEmpty)
        precondition(!env.isEnablingLibrary && env.libraryAuthorizationNotice == nil && !env.isRemovingCredentials)
        precondition(env.presentation.activePopover == nil && env.playerWindowController.invalidations == 1)
        precondition(env.artworkStore.clearCount == 1)
    }
    @MainActor static func explicitReconnect() async throws {
        for fault in [PlayerError.authDenied, .credentialCorrupt] {
            let browser = Counter(), playback = FakeStore()
            let auth = SpotifyAuthService(clientID: "synthetic", store: playback, openURL: { _ in browser.increment() })
            let env = AppEnvironment(previewPlayer: PlayerModel(), favoriteService: FakeLibrary(track:
                Track(uri: SpotifyURI("spotify:track:6rqhFgbbKwnb9MLmUQDhG6")!, title: "Synthetic", artists: [], albumTitle: nil, artwork: nil, durationMs: 100000)),
                playbackAuth: auth, recoveryEngineFactory: { _, _ in throw fault })
            await env.restoreOrPromptSignIn()
            try await wait { env.connectionStatus == .needsReauthentication || env.connectionStatus == .failed(.credentialCorrupt) }
            let reconnect = Task { await env.reconnectSpotify() }
            try await wait { browser.value == 1 }
            await env.reconnectSpotify()
            precondition(browser.value == 1, "Duplicate reconnect must not launch a second authorization")
            await env.prepareForQuit()
            await reconnect.value
            precondition(playback.hasTokens && browser.value == 1)
        }
        print("PASS: explicit expired/corrupt sign-in opens once, duplicate is ignored, quit cancels safely")
    }

    @MainActor static func staleReconnect(_ root: URL) async throws {
        let path = try directory(root, "stale-reconnect")
        defer { try? FileManager.default.removeItem(at: path) }
        let intent = LogoutIntentStore(url: path.appendingPathComponent("intent.json"))
        let playback = FakeStore(), library = FakeStore(), browser = Counter(), creates = Counter(), engine = RecoveryStubEngine()
        let (env, _) = make(intent, playback: playback, library: library, engine: engine, browser: browser, creates: creates)
        try await populate(env, engine: engine)
        await env.reconnectSpotify()
        precondition(browser.value == 0 && creates.value == 1 && env.connectionStatus == .ready,
            "A stale reconnect selection must not authorize after playback recovered")
        await env.signOut()
        await env.reconnectSpotify()
        precondition(browser.value == 0 && creates.value == 1 && env.authState == .signedOut)
        print("PASS: stale reconnect after recovery or sign-out cannot open authorization")
    }

    @MainActor static func matrix(_ root: URL, playbackFails: Bool, libraryFails: Bool) async throws {
        let path = try directory(root, "matrix")
        defer { try? FileManager.default.removeItem(at: path) }
        let url = path.appendingPathComponent("intent.json"), intent = LogoutIntentStore(url: path.appendingPathComponent("intent.json"))
        let playback = FakeStore(), library = FakeStore(), browser = Counter(), creates = Counter(), engine = RecoveryStubEngine()
        playback.failClear = playbackFails; library.failClear = libraryFails
        let (env, player) = make(intent, playback: playback, library: library, engine: engine, browser: browser, creates: creates)
        try await populate(env, engine: engine)
        let mediaStops = NowPlayingController.stops
        await env.signOut()
        assertTornDown(env, player: player)
        precondition(engine.shutdownCount == 1 && NowPlayingController.stops == mediaStops + 1)
        precondition(playback.clearCount == 1 && library.clearCount == 1)
        precondition(playback.hasTokens == playbackFails && library.hasTokens == libraryFails)
        precondition(env.authState == (playbackFails || libraryFails ? .error(.credentialCleanupRequired) : .signedOut))
        let reopened = LogoutIntentStore(url: url)
        try checked(try reopened.isPending(.playback) == playbackFails)
        try checked(try reopened.isPending(.library) == libraryFails)
        precondition(browser.value == 0 && creates.value == 1)
        if playbackFails || libraryFails {
            playback.failClear = false; library.failClear = false
            await env.signOut()
            precondition(env.authState == .signedOut && !playback.hasTokens && !library.hasTokens)
            try checked(try !LogoutIntentStore(url: url).hasPendingCleanup())
            await env.restoreOrPromptSignIn()
            precondition(env.authState == .signedOut && env.player == nil && creates.value == 1 && browser.value == 0)
        }
        print("PASS: deletion matrix playbackFailure=\(playbackFails) libraryFailure=\(libraryFails), both attempted, teardown and retry safe")
    }
    @MainActor static func startup(_ root: URL, malformed: Bool) async throws {
        let path = try directory(root, "startup")
        defer { try? FileManager.default.removeItem(at: path) }
        let url = path.appendingPathComponent("intent.json")
        if malformed { try Data("invalid".utf8).write(to: url) }
        else { try LogoutIntentStore(url: url).begin([.playback, .library]) }
        let playback = FakeStore(), library = FakeStore(), browser = Counter(), creates = Counter(), engine = RecoveryStubEngine()
        let (env, player) = make(LogoutIntentStore(url: url), playback: playback, library: library, engine: engine, browser: browser, creates: creates)
        await env.restoreOrPromptSignIn()
        assertTornDown(env, player: player)
        precondition(env.authState == .signedOut && playback.clearCount == 1 && library.clearCount == 1)
        precondition(playback.loadCount == 0 && library.loadCount == 0 && creates.value == 0 && browser.value == 0)
        try checked(try !LogoutIntentStore(url: url).hasPendingCleanup())
        print("PASS: startup malformed=\(malformed), both grants removed before any credential load or playback creation")
    }
    @MainActor static func unrecorded(_ root: URL) async throws {
        let path = try directory(root, "unrecorded")
        defer { try? FileManager.default.removeItem(at: path) }
        let live = path.appendingPathComponent("live"), parked = path.appendingPathComponent("parked")
        let url = live.appendingPathComponent("intent.json"), intent = LogoutIntentStore(url: live.appendingPathComponent("intent.json"))
        try intent.begin([])
        let playback = FakeStore(), library = FakeStore(), browser = Counter(), creates = Counter(), engine = RecoveryStubEngine()
        let (env, player) = make(intent, playback: playback, library: library, engine: engine, browser: browser, creates: creates)
        try await populate(env, engine: engine)
        try FileManager.default.moveItem(at: live, to: parked)
        try Data("obstruction".utf8).write(to: live)
        await env.signOut()
        assertTornDown(env, player: player)
        precondition(env.authState == .error(.credentialCleanupNotRecorded))
        precondition(playback.clearCount == 0 && library.clearCount == 0 && playback.hasTokens && library.hasTokens && engine.shutdownCount == 1)
        precondition(browser.value == 0 && creates.value == 1)
        try FileManager.default.removeItem(at: live)
        try FileManager.default.moveItem(at: parked, to: live)
        await env.signOut()
        precondition(env.authState == .signedOut && !playback.hasTokens && !library.hasTokens)
        try checked(try !LogoutIntentStore(url: url).hasPendingCleanup())
        print("PASS: intent commit failure defers both deletions, still stops engine, reports restart caveat; repair permits cleanup")
    }
    @MainActor static func quit(_ root: URL) async throws {
        let path = try directory(root, "quit")
        defer { try? FileManager.default.removeItem(at: path) }
        let intent = LogoutIntentStore(url: path.appendingPathComponent("intent.json"))
        let playback = FakeStore(), library = FakeStore(), browser = Counter(), creates = Counter(), engine = RecoveryStubEngine()
        let (env, _) = make(intent, playback: playback, library: library, engine: engine, browser: browser, creates: creates)
        try await populate(env, engine: engine)
        await env.prepareForQuit()
        precondition(playback.hasTokens && library.hasTokens && playback.clearCount == 0 && library.clearCount == 0)
        precondition(engine.shutdownCount == 1 && env.player == nil && env.recovery == nil && browser.value == 0)
        try checked(try !intent.hasPendingCleanup())
        print("PASS: quit preserves both grants and stops synthetic engine without logout intent")
    }
}
