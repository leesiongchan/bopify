import Foundation
import Observation
import os
import BopifyAuth
import BopifyDomain
import BopifyPlayback
import BopifyLibrary

/// The only place concrete implementations are chosen.
///
/// Holds the concrete `LibrespotEngine` alongside the type-erased
/// `PlayerModel`, not just the model: `shutdown()` is not on the
/// `PlaybackEngine` protocol, so `PlayerModel`'s `any PlaybackEngine` erases
/// the only route to teardown. This is the composition root, so its
/// lifetime is the app's — engine creation belongs here, not in a view's
/// `.task`, because `LibrespotEngine.init` blocks for a whole network login
/// with no cancellation check.
@MainActor
@Observable
final class AppEnvironment {
    private(set) var authState: AuthState = .signedOut
    private(set) var player: PlayerModel?
    let artworkStore = ArtworkStore()
    let favorite: FavoriteModel
    private(set) var isEnablingFavorites = false
    private(set) var favoriteAuthorizationNotice: String?
    let presentation = PlayerPresentation(
        mode: PlayerMode(rawValue: UserDefaults.standard.string(forKey: "player.mode") ?? "") ?? .expanded,
        keepOnTop: UserDefaults.standard.bool(forKey: "player.keepOnTop"))

    var playerMode: PlayerMode {
        authState == .signedIn && player?.state.currentTrack != nil ? presentation.mode : .expanded
    }

    // A Developer Dashboard client ID is rejected by login5 with HTTP 400
    // (see BopifyAuth's `librespotClientID` doc comment), so the same ID
    // used for the librespot session is also the one used here.
    @ObservationIgnored private let auth: SpotifyAuthService
    @ObservationIgnored private var engine: LibrespotEngine?

    /// `engine == nil` cannot serve as a lock: it cannot distinguish "torn
    /// down" from "teardown in flight", and a check at the top of a function
    /// says nothing about what happens across the awaits below it. Every
    /// operation that touches `engine`, `player`, or the auth session is
    /// funneled through `serialize` instead, so each one runs only after
    /// the previous one has fully finished — including quit waiting out an
    /// in-flight sign-out so the keychain actually clears before the app
    /// terminates, rather than racing it.
    @ObservationIgnored private var pending: Task<Void, Never> = Task {}

    /// `signIn()`'s in-flight guard used to read `authState`, but `authState`
    /// is mutated inside `serialize`d blocks belonging to *other*
    /// operations too — an enqueued sign-out can overwrite it out from under
    /// a sign-in still waiting in the chain. A guard is only as good as the
    /// thing it reads, so this tracks sign-in-in-flight on its own, and
    /// `authState` goes back to being purely a description of what the UI
    /// should show.
    @ObservationIgnored private var signInRequested = false

    init() {
        let auth = SpotifyAuthService(clientID: librespotClientID)
        self.auth = auth
        favorite = FavoriteModel(service: SpotifyLibraryClient { scopes in
            try await auth.validAccessToken(requiredScopes: scopes)
        })
    }

    func refreshFavorite() async {
        guard authState == .signedIn else { favorite.clear(); return }
        await favorite.select(player?.state.currentTrack?.uri)
    }

    func enableFavorites() async {
        guard authState == .signedIn, !isEnablingFavorites else { return }
        isEnablingFavorites = true
        favoriteAuthorizationNotice = nil
        defer { isEnablingFavorites = false }
        do {
            _ = try await auth.authorizeAdditionalScopes(["user-library-read", "user-library-modify"])
            guard authState == .signedIn else { return }
            await refreshFavorite()
        } catch {
            guard authState == .signedIn else { return }
            favoriteAuthorizationNotice = String(localized: "favorite.consentFailed")
            BopifyLog.library.notice("favorite authorization did not complete")
        }
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
        await serialize { [self] in
            // Shown as authenticating rather than left signedOut: a restore
            // that finds a token still has to reach Spotify before playback
            // can start, and signedOut would offer a redundant "Sign In"
            // button for the whole restore window.
            authState = .authenticating
            if await auth.restore() != nil {
                await connect()
            } else {
                authState = .signedOut
            }
        }
    }

    func signIn() async {
        // Not redundant with `serialize`: this rejects a second whole OAuth
        // round-trip while one is already open, rather than just running
        // two of them back to back. Guards on its own flag, not `authState`
        // — an operation ahead of this one in the chain (a sign-out) can
        // still be running when this is called, and it owns `authState`
        // until its block finishes.
        guard !signInRequested else {
            BopifyLog.auth.notice("sign-in skipped: already authenticating")
            return
        }
        signInRequested = true
        await serialize { [self] in
            defer { signInRequested = false }
            authState = .authenticating
            do {
                _ = try await auth.signIn()
                await connect()
            } catch {
                let playerError = error as? PlayerError ?? .unknown
                BopifyLog.auth.error("sign-in failed error=\(String(describing: playerError), privacy: .public)")
                authState = .error(playerError)
            }
        }
    }

    func signOut() async {
        await serialize { [self] in
            BopifyLog.auth.info("sign-out starting")
            player?.stop()
            player = nil
            artworkStore.clear()
            favorite.clear()
            favoriteAuthorizationNotice = nil
            // Set before the teardown `await`, not after: `engine.shutdown()`
            // can take multiple seconds, and leaving `authState` at `.signedIn`
            // across that suspension makes the UI fall through to the
            // "signing in" presentation for someone who is signing out.
            authState = .signedOut
            if let engine {
                self.engine = nil
                await engine.shutdown()
            }
            await auth.signOut()
        }
    }

    /// Quit tears the engine down but must not sign out: AUTH-05 requires
    /// the session to survive a quit and relaunch, so the keychain is left
    /// alone. Do not reuse `signOut()` here. Going through `serialize` means
    /// a quit that lands mid-sign-out waits for that sign-out's keychain
    /// clear to actually run before this returns and the caller terminates.
    func prepareForQuit() async {
        await serialize { [self] in
            BopifyLog.playback.info("prepare for quit starting")
            favorite.clear()
            player?.stop()
            player = nil
            if let engine {
                self.engine = nil
                await engine.shutdown()
            }
            BopifyLog.playback.info("prepare for quit complete")
        }
    }

    /// Only ever called from inside a `serialize`d operation above. Never
    /// enqueue another one from in here — that would await a chain link
    /// that is itself still waiting to run.
    private func connect() async {
        do {
            let token = try await auth.validAccessToken()
            // Runs off the main actor: the package is built in Swift 6
            // language mode without NonisolatedNonsendingByDefault, so a
            // `nonisolated async` initialiser already hops to the global
            // executor. The `@concurrent` on it guards against that default
            // changing, rather than being what saves us today.
            let engine = try await LibrespotEngine(accessToken: token, deviceName: "Bopify")
            let model = PlayerModel(engine: engine)
            model.start()
            // No activate(): the engine restores the last session or loads Liked Songs itself,
            // and stays inactive when another device is playing so it is not interrupted.
            // Today the UI and `serialize` make a second connect unreachable,
            // so this teardown is structural rather than load-bearing: the
            // cost of being wrong is a leaked Rust runtime and audio thread
            // for the process lifetime, which no test would catch.
            await self.engine?.shutdown()
            player?.stop()
            self.engine = engine
            player = model
            authState = .signedIn
            BopifyLog.auth.info("connect succeeded")
        } catch {
            let playerError = error as? PlayerError ?? .unknown
            BopifyLog.auth.error("connect failed error=\(String(describing: playerError), privacy: .public)")
            authState = .error(playerError)
        }
    }
}
