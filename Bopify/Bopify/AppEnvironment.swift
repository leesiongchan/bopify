import Foundation
import Observation
import os
import BopifyAuth
import BopifyDomain
import BopifyPlayback

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

    // A Developer Dashboard client ID is rejected by login5 with HTTP 400
    // (see BopifyAuth's `librespotClientID` doc comment), so the same ID
    // used for the librespot session is also the one used here.
    @ObservationIgnored private let auth = SpotifyAuthService(clientID: librespotClientID)
    @ObservationIgnored private var engine: LibrespotEngine?

    func restoreOrPromptSignIn() async {
        if await auth.restore() != nil { await connect() }
    }

    func signIn() async {
        // A second tap while the first sign-in is still in flight would
        // otherwise enqueue a second `signIn()`; the auth service's
        // generation guard then makes the loser throw *after* the winner
        // reached `.signedIn`, showing a failure over playing audio.
        guard authState != .authenticating else {
            BopifyLog.auth.notice("sign-in skipped: already authenticating")
            return
        }
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

    func signOut() async {
        BopifyLog.auth.info("sign-out starting")
        player?.stop()
        player = nil
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

    /// Quit tears the engine down but must not sign out: AUTH-05 requires
    /// the session to survive a quit and relaunch, so the keychain is left
    /// alone. Do not reuse `signOut()` here.
    func prepareForQuit() async {
        BopifyLog.playback.info("prepare for quit starting")
        player?.stop()
        player = nil
        if let engine {
            self.engine = nil
            await engine.shutdown()
        }
        BopifyLog.playback.info("prepare for quit complete")
    }

    private func connect() async {
        // A second `connect()` racing in (e.g. a second sign-in completing
        // for the already-signed-in case) must not clobber a live engine:
        // `LibrespotEngine.deinit` deliberately does not destroy, so
        // overwriting `self.engine` without shutting the old one down first
        // leaks the Rust runtime and librespot's audio thread for good.
        guard engine == nil else {
            BopifyLog.auth.notice("connect skipped: engine already active")
            return
        }
        do {
            let token = try await auth.validAccessToken()
            // `LibrespotEngine.init` is `@concurrent`, so this call already
            // runs off the main actor; no separate wrapper is needed.
            let engine = try await LibrespotEngine(accessToken: token, deviceName: "Bopify")
            let model = PlayerModel(engine: engine)
            model.start()
            model.activate()
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
