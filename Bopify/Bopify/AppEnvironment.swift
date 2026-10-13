import Foundation
import Observation
import os
import BopifyAuth
import BopifyDomain
import BopifyPlayback
import BopifyLibrary

/// Chooses concrete services and owns the stable player across engine replacements.
@MainActor
@Observable
final class AppEnvironment {
    private(set) var authState: AuthState = .signedOut
    private(set) var player: PlayerModel?
    @ObservationIgnored private var nowPlaying: NowPlayingController?
    let artworkStore: ArtworkStore
    let favorite: FavoriteModel
    let likedSongs: LikedSongsModel
    let recents: RecentsModel
    let explore: ExploreModel
    @ObservationIgnored private let stations: StationRoute
    private(set) var isEnablingLibrary = false
    private(set) var libraryAuthorizationNotice: String?
    @ObservationIgnored private let authorizeLibraryScopes: @Sendable (Set<String>) async throws -> Void
    @ObservationIgnored private var libraryGeneration = 0
    let presentation = PlayerPresentation(
        mode: .compact,
        keepOnTop: UserDefaults.standard.bool(forKey: "player.keepOnTop"))
    let playerWindowController = PlayerWindowController(defaults: .standard)
    var isListening: Bool {
        authState == .signedIn && (player?.state.currentTrack != nil || player?.state.mirror != nil)
    }

    var playerMode: PlayerMode {
        isListening ? presentation.mode : .expanded
    }

    @ObservationIgnored private let auth: SpotifyAuthService
    @ObservationIgnored private let libraryAuth: LibraryAuthorization
    private(set) var libraryClientID: String?
    let librarySetupWindow = LibrarySetupWindowController()
    private(set) var librarySetupError: PlayerError?
    // The scopes an Enable action asked for before any client ID existed; consent resumes after setup.
    @ObservationIgnored private var pendingLibraryScopes: Set<String> = []
    private(set) var recovery: PlaybackRecoveryCoordinator?
    var connectionStatus: PlaybackConnectionStatus { recovery?.status ?? .ready }
    @ObservationIgnored private var connectionMonitor: PlaybackConnectionMonitor?
    @ObservationIgnored private var sessionGeneration = 0
    @ObservationIgnored private var makeRecoveryEngine: @Sendable (String, PlaybackEngineConfiguration) async throws -> any ManagedPlaybackEngine = { token, options in
        try await LibrespotEngine(accessToken: token, deviceName: "Bopify", configuration: options)
    }
    @ObservationIgnored private var monitorEnabled = true

    // Authorization and final teardown remain serialized; recovery has its own worker.
    @ObservationIgnored private var pending: Task<Void, Never> = Task {}

    /// `signIn()`'s in-flight guard used to read `authState`, but `authState`
    /// is mutated inside `serialize`d blocks belonging to *other*
    /// operations too — an enqueued sign-out can overwrite it out from under
    /// a sign-in still waiting in the chain. A guard is only as good as the
    /// thing it reads, so this tracks sign-in-in-flight on its own, and
    /// `authState` goes back to being purely a description of what the UI
    /// should show.
    @ObservationIgnored private var isSignInInFlight = false

    init() {
        let auth = SpotifyAuthService(clientID: librespotClientID)
        let libraryAuth = LibraryAuthorization { clientID in
            SpotifyAuthService(clientID: clientID,
                               store: KeychainTokenStore(service: "com.leesiongchan.bopify.library"),
                               callbackPort: 8898, callbackPath: "/callback")
        }
        self.auth = auth
        self.libraryAuth = libraryAuth
        libraryClientID = LibraryAuthorization.storedClientID(in: .standard)
        artworkStore = ArtworkStore()
        let library = SpotifyLibraryClient { scopes in
            try await libraryAuth.validAccessToken(requiredScopes: scopes)
        }
        favorite = FavoriteModel(service: library)
        likedSongs = LikedSongsModel(service: library)
        let stations = StationRoute()
        self.stations = stations
        recents = RecentsModel(service: library)
        explore = ExploreModel(history: library, savedTracks: library, radio: { try await stations.mix(for: $0) })
        authorizeLibraryScopes = { scopes in try await libraryAuth.authorize(scopes) }
    }

    #if DEBUG
    init(previewPlayer: PlayerModel, favoriteService: any LibraryService,
         savedTracksService: (any SavedTracksService)? = nil,
         historyService: (any ListeningHistoryService)? = nil,
         authorizeLibraryScopes: (@Sendable (Set<String>) async throws -> Void)? = nil,
         playbackAuth: SpotifyAuthService? = nil,
         libraryAuth: SpotifyAuthService? = nil,
         artworkStore: ArtworkStore = ArtworkStore(),
         radioEngine: (any PlaybackEngine)? = nil,
         recoveryEngineFactory: (@Sendable (String, PlaybackEngineConfiguration) async throws -> any ManagedPlaybackEngine)? = nil) {
        auth = playbackAuth ?? SpotifyAuthService(clientID: librespotClientID,
            store: KeychainTokenStore(service: "com.leesiongchan.bopify.preview.\(UUID().uuidString)"))
        // A temp-path suite keeps previews out of ~/Library/Preferences.
        // The actor reads the ID in init, so the domain can go at once.
        let previewSuite = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.leesiongchan.bopify.preview.\(UUID().uuidString)").path
        let previewDefaults = UserDefaults(suiteName: previewSuite)!
        previewDefaults.set(String(repeating: "0", count: 32), forKey: LibraryAuthorization.defaultsKey)
        let previewLibraryAuth = libraryAuth ?? SpotifyAuthService(clientID: String(repeating: "0", count: 32),
            store: KeychainTokenStore(service: "com.leesiongchan.bopify.preview.library.\(UUID().uuidString)"))
        self.libraryAuth = LibraryAuthorization(suiteName: previewSuite) { _ in previewLibraryAuth }
        previewDefaults.removePersistentDomain(forName: previewSuite)
        libraryClientID = String(repeating: "0", count: 32)
        self.artworkStore = artworkStore
        favorite = FavoriteModel(service: favoriteService)
        likedSongs = LikedSongsModel(service: savedTracksService ?? UnavailableSavedTracks())
        let stations = StationRoute()
        stations.engine = radioEngine
        self.stations = stations
        recents = RecentsModel(service: historyService ?? UnavailableHistory())
        explore = ExploreModel(history: historyService ?? UnavailableHistory(),
                               savedTracks: savedTracksService ?? UnavailableSavedTracks(),
                               radio: { try await stations.mix(for: $0) })
        self.authorizeLibraryScopes = authorizeLibraryScopes ?? { _ in throw LibraryError.unavailable }
        player = previewPlayer
        authState = .signedIn
        if let recoveryEngineFactory { makeRecoveryEngine = recoveryEngineFactory; monitorEnabled = false }
    }
    #endif

    func refreshFavorite() async {
        guard authState == .signedIn else { favorite.clear(); return }
        await favorite.select(player?.state.currentTrack?.uri)
    }

    func enableFavorites() async {
        await enableLibrary(scopes: ["user-library-read", "user-library-modify"])
    }

    func enableLikedSongs() async {
        await enableLibrary(scopes: ["user-library-read"])
    }

    func enableListeningHistory() async {
        await enableLibrary(scopes: ["user-read-recently-played", "user-top-read"])
    }

    private func enableLibrary(scopes: Set<String>) async {
        guard authState == .signedIn, !isEnablingLibrary else { return }
        guard libraryClientID != nil else {
            pendingLibraryScopes.formUnion(scopes)
            librarySetupWindow.show(environment: self)
            BopifyLog.library.info("library setup requested")
            return
        }
        isEnablingLibrary = true
        libraryAuthorizationNotice = nil
        let generation = libraryGeneration
        defer { if generation == libraryGeneration { isEnablingLibrary = false } }
        do {
            try await authorizeLibraryScopes(scopes)
            guard authState == .signedIn, generation == libraryGeneration else { return }
            await refreshFavorite()
            guard generation == libraryGeneration else { return }
            await likedSongs.refresh()
            guard generation == libraryGeneration else { return }
            await recents.refresh()
            guard generation == libraryGeneration else { return }
            await explore.refresh()
        } catch {
            guard authState == .signedIn, generation == libraryGeneration else { return }
            libraryAuthorizationNotice = String(localized: "favorite.consentFailed")
            BopifyLog.library.notice("library authorization did not complete")
        }
    }

    func setLibraryClientID(_ raw: String) async {
        guard LibraryAuthorization.normalized(raw) != nil else { return }
        librarySetupError = nil
        // Abandon active consent before it can post a stale notice; preserve a rotated
        // grant waiting for persistence when Save does not interrupt consent.
        let hadPendingConsent = isEnablingLibrary
        libraryGeneration += 1
        isEnablingLibrary = false
        if hadPendingConsent { await libraryAuth.cancelPendingWork() }
        let previous = libraryClientID
        let id: String
        do { id = try await libraryAuth.setClientID(raw) }
        catch {
            librarySetupError = error as? PlayerError ?? .credentialUnavailable
            BopifyLog.library.error("library setup could not remove the previous grant")
            return
        }
        BopifyLog.library.info("library setup saved; pendingConsent=\(hadPendingConsent, privacy: .public)")
        libraryClientID = id
        librarySetupWindow.close()
        if let previous, id != previous { clearLibrary() }
        let scopes = pendingLibraryScopes
        pendingLibraryScopes = []
        // Unstructured so Save returns once the ID is stored rather than when consent ends.
        if !scopes.isEmpty { Task { await enableLibrary(scopes: scopes) } }
    }

    private func clearLibrary() {
        libraryGeneration += 1
        isEnablingLibrary = false
        libraryAuthorizationNotice = nil
        favorite.clear()
        likedSongs.clear()
        recents.clear()
        explore.clear()
    }

    private func serialize(_ operation: @escaping @MainActor () async -> Void) async {
        let previous = pending
        let task = Task { @MainActor in
            await previous.value
            await operation()
        }
        pending = task
        BopifyLog.playback.debug("engine lifecycle operation enqueued")
        await task.value
    }

    func restoreOrPromptSignIn() async {
        let generation = sessionGeneration
        await serialize { [self] in
            guard generation == sessionGeneration else { return }
            authState = .refreshing
            do {
                let restored = try await auth.restore()
                guard generation == sessionGeneration else { return }
                if restored != nil { connect() } else { authState = .signedOut }
            } catch {
                guard generation == sessionGeneration else { return }
                authState = .error(error as? PlayerError ?? .credentialUnavailable)
            }
        }
    }

    func signIn() async {
        guard !isSignInInFlight else { return }
        isSignInInFlight = true
        let generation = sessionGeneration
        await serialize { [self] in
            defer { isSignInInFlight = false }
            guard generation == sessionGeneration else { return }
            authState = .authenticating
            do {
                _ = try await auth.signIn()
                guard generation == sessionGeneration else { return }
                connect()
            } catch {
                guard generation == sessionGeneration else { return }
                authState = .error(error as? PlayerError ?? .unknown)
            }
        }
    }

    func retryPlaybackConnection() { recovery?.retryNow() }

    func reconnectSpotify() async {
        guard !isSignInInFlight, authState == .signedIn else { return }
        isSignInInFlight = true
        let generation = sessionGeneration
        await serialize { [self] in
            defer { isSignInInFlight = false }
            guard generation == sessionGeneration else { return }
            do {
                _ = try await auth.signIn()
                guard generation == sessionGeneration else { return }
                recovery?.start()
            } catch {
                BopifyLog.auth.notice("playback reauthorization did not complete")
            }
        }
    }

    func signOut() async {
        sessionGeneration += 1
        connectionMonitor?.stop()
        recovery?.invalidate()
        authState = .signedOut
        pendingLibraryScopes = []
        let clearingAuth = Task { [auth] in await auth.signOut() }
        await serialize { [self] in
            await clearingAuth.value
            BopifyLog.auth.info("sign-out starting")
            await recovery?.stop()
            recovery = nil
            connectionMonitor = nil
            stations.engine = nil
            presentation.resetEngagement()
            playerWindowController.invalidateTransition()
            nowPlaying?.stop()
            nowPlaying = nil
            player?.stop()
            player = nil
            artworkStore.clear()
            clearLibrary()
            await libraryAuth.signOut()
        }
    }

    func prepareForQuit() async {
        sessionGeneration += 1
        connectionMonitor?.stop()
        recovery?.invalidate()
        let cancellingAuth = Task { [auth, libraryAuth] in
            await auth.cancelPendingWork()
            await libraryAuth.cancelPendingWork()
        }
        await serialize { [self] in
            await cancellingAuth.value
            await recovery?.stop()
            recovery = nil
            connectionMonitor = nil
            stations.engine = nil
            clearLibrary()
            nowPlaying?.stop()
            nowPlaying = nil
            player?.stop()
            player = nil
            BopifyLog.playback.info("prepare for quit complete")
        }
    }

    // Called only inside serialize; the retry loop returns immediately and owns its lifetime.
    private func connect() {
        if recovery != nil { recovery?.start(); authState = .signedIn; return }
        let model = player ?? PlayerModel()
        player = model
        let auth = self.auth
        let coordinator = PlaybackRecoveryCoordinator(player: model, tokenProvider: { rejected in
            if let rejected { return try await auth.validAccessToken(rejecting: rejected) }
            return try await auth.validAccessToken()
        }, makeEngine: makeRecoveryEngine)
        coordinator.onEngineChange = { [weak stations, weak coordinator] engine in
            stations?.engine = engine
            stations?.coordinator = coordinator
            stations?.epoch = model.engineEpoch
        }
        recovery = coordinator
        nowPlaying = NowPlayingController(player: model, artworkStore: artworkStore)
        authState = .signedIn
        if monitorEnabled {
            let monitor = PlaybackConnectionMonitor(coordinator: coordinator)
            connectionMonitor = monitor
            monitor.start()
        }
        coordinator.start()
        BopifyLog.auth.info("credentials restored; playback connection scheduled")
    }

}

/// Explore's way to the current engine: the engine is created after the models and replaced on reconnect or sign-out, so the model cannot hold it.
@MainActor
private final class StationRoute {
    var engine: (any PlaybackEngine)?
    weak var coordinator: PlaybackRecoveryCoordinator?
    var epoch: UInt64 = 0

    func mix(for seed: SpotifyURI) async throws -> RadioMix {
        guard let engine, coordinator?.player.isEngineReady != false else { throw RadioFailure.unavailable }
        let dispatchedEpoch = epoch
        do { return try await engine.requestRadio(seed: seed) }
        catch {
            if error as? PlayerError == .playbackSessionLost {
                coordinator?.reportSessionLoss(.commandFailed, epoch: dispatchedEpoch)
            }
            throw error
        }
    }
}

#if DEBUG
private struct UnavailableHistory: ListeningHistoryService {
    func recentlyPlayed() async throws -> [RecentPlay] { throw LibraryError.unavailable }
    func topItems(_ kind: TopItemKind) async throws -> [StationSeed] { throw LibraryError.unavailable }
}

private struct UnavailableSavedTracks: SavedTracksService {
    func savedTracks(offset: Int, limit: Int) async throws -> SavedTracksPage { throw LibraryError.unavailable }
}
#endif
