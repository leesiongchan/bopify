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
        if let engine {
            self.engine = nil
            await engine.shutdown()
        }
        await auth.signOut()
        authState = .signedOut
    }

    private func connect() async {
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
