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
    private(set) var isRemovingCredentials = false
    @ObservationIgnored private let logoutIntent: LogoutIntentStore?
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
    @ObservationIgnored private var libraryAuthorization: Task<Void, Never>?
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

    #if DEBUG
    @ObservationIgnored private(set) var liveLyricRibbon: LiveLyricRibbonSession?
    var isLiveLyricsVisible: Bool { liveLyricRibbon?.isVisible ?? false }

    func showLiveLyrics() {
        guard authState == .signedIn, let player, let coordinator = recovery else { return }
        if liveLyricRibbon == nil {
            liveLyricRibbon = LiveLyricRibbonSession(player: player) { [weak coordinator] uri, epoch in
                guard let coordinator, coordinator.player.engineEpoch == epoch,
                      coordinator.player.isEngineReady, let engine = coordinator.currentEngine else {
                    throw LyricFailure.unavailable
                }
                do { return try await engine.requestLyrics(for: uri) }
                catch {
                    if error as? PlayerError == .playbackSessionLost {
                        coordinator.reportSessionLoss(.commandFailed, epoch: epoch)
                    }
                    throw error
                }
            }
        }
        liveLyricRibbon?.show()
        BopifyLog.playback.debug("live lyric ribbon shown")
    }

    func hideLiveLyrics() { liveLyricRibbon?.hide() }

    func focusLiveLyrics() {
        guard authState == .signedIn, player != nil else { return }
        showLiveLyrics()
        liveLyricRibbon?.focusForReading()
    }

    private func stopLiveLyrics() {
        liveLyricRibbon?.shutdown()
        liveLyricRibbon = nil
        BopifyLog.playback.debug("live lyric ribbon stopped")
    }
    #endif

    // Authorization and final teardown remain serialized; recovery has its own worker.
    @ObservationIgnored private var pending: Task<Void, Never> = Task {}

    // Queued lifecycle operations can change authState while consent is still pending.
    private(set) var isAuthorizingPlayback = false
    @ObservationIgnored private var playbackAuthorization: Task<Void, Never>?

    init() {
        let intent = LogoutIntentStore()
        logoutIntent = intent
        let auth = SpotifyAuthService(clientID: librespotClientID, logoutIntent: intent)
        let libraryStore = KeychainTokenStore(service: "com.leesiongchan.bopify.library")
        let libraryAuth = LibraryAuthorization(orphanedStore: libraryStore, logoutIntent: intent) { clientID in
            SpotifyAuthService(clientID: clientID, store: libraryStore,
                               logoutIntent: intent, credentialNamespace: .library,
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
         logoutIntent: LogoutIntentStore? = nil,
         artworkStore: ArtworkStore = ArtworkStore(),
         radioEngine: (any PlaybackEngine)? = nil,
         recoveryEngineFactory: (@Sendable (String, PlaybackEngineConfiguration) async throws -> any ManagedPlaybackEngine)? = nil) {
        self.logoutIntent = logoutIntent
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
        let generation = libraryGeneration
        let task = Task { [self] in
            defer {
                if generation == libraryGeneration { isEnablingLibrary = false; libraryAuthorization = nil }
            }
            do {
                try await authorizeLibraryScopes(scopes)
                try Task.checkCancellation()
                guard authState == .signedIn, generation == libraryGeneration else { return }
                await refreshFavorite()
                guard generation == libraryGeneration, !Task.isCancelled else { return }
                await likedSongs.refresh()
                guard generation == libraryGeneration, !Task.isCancelled else { return }
                await recents.refresh()
                guard generation == libraryGeneration, !Task.isCancelled else { return }
                await explore.refresh()
            } catch is CancellationError {
                BopifyLog.library.info("library authorization cancelled")
            } catch {
                guard authState == .signedIn, generation == libraryGeneration else { return }
                libraryAuthorizationNotice = String(localized: "favorite.consentFailed")
                BopifyLog.library.notice("library authorization did not complete")
            }
        }
        libraryAuthorization = task
        libraryAuthorizationNotice = nil
        isEnablingLibrary = true
        await task.value
    }

    func cancelPlaybackAuthorization() {
        playbackAuthorization?.cancel()
        BopifyLog.auth.info("playback authorization cancellation requested")
    }

    func cancelLibraryAuthorization() {
        libraryAuthorization?.cancel()
        BopifyLog.library.info("library authorization cancellation requested")
    }

    func setLibraryClientID(_ raw: String) async {
        guard !isRemovingCredentials, !hasPendingCleanup else {
            librarySetupError = .credentialCleanupRequired
            return
        }
        guard LibraryAuthorization.normalized(raw) != nil else { return }
        librarySetupError = nil
        // Abandon active consent before it can post a stale notice; preserve a rotated
        // grant waiting for persistence when Save does not interrupt consent.
        let hadPendingConsent = isEnablingLibrary
        libraryAuthorization?.cancel()
        libraryAuthorization = nil
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
        libraryAuthorization?.cancel()
        libraryAuthorization = nil
        libraryGeneration += 1
        isEnablingLibrary = false
        libraryAuthorizationNotice = nil
        favorite.clear()
        likedSongs.clear()
        recents.clear()
        explore.clear()
    }

    private func serialize(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = pending
        let task = Task { @MainActor in
            await previous.value
            await operation()
        }
        pending = task
        BopifyLog.playback.debug("engine lifecycle operation enqueued")
        return task
    }

    private var hasPendingCleanup: Bool {
        do { return try logoutIntent?.hasPendingCleanup() ?? false }
        catch { return true }
    }

    func restoreOrPromptSignIn() async {
        guard !isRemovingCredentials else { return }
        if hasPendingCleanup { await signOut(); return }
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
        }.value
    }

    func signIn() async {
        guard !isAuthorizingPlayback, !isRemovingCredentials else { return }
        if hasPendingCleanup {
            await signOut()
            guard authState == .signedOut else { return }
        }
        isAuthorizingPlayback = true
        let generation = sessionGeneration
        let task = serialize { [self] in
            defer { isAuthorizingPlayback = false; playbackAuthorization = nil }
            guard generation == sessionGeneration else { return }
            do {
                try Task.checkCancellation()
                authState = .authenticating
                _ = try await auth.signIn()
                guard generation == sessionGeneration else { return }
                connect()
            } catch is CancellationError {
                guard generation == sessionGeneration else { return }
                authState = .signedOut
                BopifyLog.auth.info("sign-in cancelled")
            } catch {
                guard generation == sessionGeneration else { return }
                authState = .error(error as? PlayerError ?? .unknown)
            }
        }
        playbackAuthorization = task
        await task.value
    }

    func retryPlaybackConnection() { recovery?.retryNow() }

    func reconnectSpotify() async {
        guard !isAuthorizingPlayback, authState == .signedIn, needsPlaybackReauthentication else {
            BopifyLog.auth.debug("Playback reauthorization ignored: no current request or authorization already pending")
            return
        }
        isAuthorizingPlayback = true
        let generation = sessionGeneration
        let task = serialize { [self] in
            defer { isAuthorizingPlayback = false; playbackAuthorization = nil }
            guard generation == sessionGeneration, needsPlaybackReauthentication else {
                BopifyLog.auth.debug("Queued playback reauthorization discarded after connection or session changed")
                return
            }
            do {
                try Task.checkCancellation()
                _ = try await auth.signIn()
                guard generation == sessionGeneration else { return }
                recovery?.start()
            } catch {
                BopifyLog.auth.notice("playback reauthorization did not complete")
            }
        }
        playbackAuthorization = task
        await task.value
    }

    private var needsPlaybackReauthentication: Bool {
        connectionStatus == .needsReauthentication || connectionStatus == .failed(.credentialCorrupt)
    }

    func signOut() async {
        guard !isRemovingCredentials else { return }
        #if DEBUG
        stopLiveLyrics()
        #endif
        isRemovingCredentials = true
        playbackAuthorization?.cancel()
        libraryAuthorization?.cancel()
        defer { isRemovingCredentials = false }
        sessionGeneration += 1
        connectionMonitor?.stop()
        recovery?.invalidate()
        authState = .signedOut
        pendingLibraryScopes = []
        do { try logoutIntent?.begin([.playback, .library]) }
        catch { BopifyLog.auth.error("logout intent could not be persisted; retrying intent for both stores") }
        let clearingAuth = Task { [auth] in
            do { try await auth.signOut(); return nil as PlayerError? }
            catch { return error as? PlayerError ?? .credentialCleanupRequired }
        }
        let clearingLibrary = Task { [libraryAuth] in
            do { try await libraryAuth.signOut(); return nil as PlayerError? }
            catch { return error as? PlayerError ?? .credentialCleanupRequired }
        }
        await serialize { [self] in
            let playbackError = await clearingAuth.value
            let libraryError = await clearingLibrary.value
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
            if playbackError != nil || libraryError != nil || hasPendingCleanup {
                let notRecorded = playbackError == .credentialCleanupNotRecorded || libraryError == .credentialCleanupNotRecorded
                authState = .error(notRecorded ? .credentialCleanupNotRecorded : .credentialCleanupRequired)
                BopifyLog.auth.error("signed out with credential cleanup pending")
            } else {
                BopifyLog.auth.info("sign-out credential cleanup complete")
            }
        }.value
    }

    func prepareForQuit() async {
        #if DEBUG
        stopLiveLyrics()
        #endif
        playbackAuthorization?.cancel()
        libraryAuthorization?.cancel()
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
        }.value
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
            let monitor = PlaybackConnectionMonitor(coordinator: coordinator) { [weak artworkStore] in
                artworkStore?.retryFailedLoads(connectivityRestored: true)
            }
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
