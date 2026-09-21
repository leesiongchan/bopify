import AppKit
import Foundation
import os
import BopifyDomain

/// librespot's first-party Spotify client ID, and the only one that can
/// reach the streaming endpoint -- a Developer Dashboard ID is rejected
/// by login5 with HTTP 400 (see docs/superpowers/specs/2026-09-21-spike-findings.md).
/// Spotify may revoke it at any time, which is the realistic failure
/// mode for this app; keeping it in one place makes that a one-line fix.
public let librespotClientID = "65b708073fc0480ea92a077233ca87bd"

public actor SpotifyAuthService {
    private let clientID: String
    private let client: TokenClient
    private let store: any TokenStoring
    private let openURL: @Sendable (URL) -> Void
    private var tokens: TokenSet?
    /// Actors are reentrant across `await`: `signOut()` can finish while
    /// `signIn()`/`validAccessToken()` are suspended mid-flight. `signOut()`
    /// and `signIn()` bump this on entry and both check it before persisting,
    /// so a sign-out (or a fresher sign-in) discards stale in-flight work.
    /// `validAccessToken()` only checks it, guarding against a `signOut()`
    /// mid-refresh -- not against two overlapping refreshes.
    ///
    /// This defends the actor's own contract, for any caller. Bopify's app
    /// additionally serialises every auth operation through
    /// `AppEnvironment.serialize`, so in-app the interleaving this guards
    /// against cannot arise; only the tests construct it directly.
    private var generation = 0

    public init(
        clientID: String,
        client: TokenClient? = nil,
        store: any TokenStoring = KeychainTokenStore(),
        openURL: @Sendable @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.clientID = clientID
        self.client = client ?? TokenClient(clientID: clientID)
        self.store = store
        self.openURL = openURL
    }

    public func restore() -> TokenSet? {
        tokens = store.load()
        let found = tokens != nil
        BopifyLog.auth.debug("restore found=\(found, privacy: .public)")
        return tokens
    }

    public func signIn() async throws -> TokenSet {
        generation += 1
        let myGeneration = generation
        BopifyLog.auth.info("signIn starting generation=\(myGeneration, privacy: .public)")
        let pkce = PKCEPair.random()
        let state = UUID().uuidString
        let listener = LoopbackCallbackListener(expectedState: state)
        let port = try await listener.start()
        BopifyLog.auth.debug("callback listener bound port=\(port, privacy: .public)")
        defer { Task { await listener.stop() } }

        let redirectURI = "http://127.0.0.1:\(port)/login"
        let request = AuthorizationRequest(clientID: clientID, redirectURI: redirectURI,
                                           scopes: ["streaming"], pkce: pkce, state: state)
        openURL(request.url)
        BopifyLog.auth.info("opened system browser for authorization")

        let code: String
        do { code = try await listener.waitForCallback() }
        catch CallbackError.accessDenied {
            BopifyLog.auth.notice("user declined consent")
            throw PlayerError.authDenied
        }
        catch {
            let description = String(describing: error)
            BopifyLog.auth.error("callback wait failed error=\(description, privacy: .public)")
            throw PlayerError.invalidCallback
        }

        let tokens = try await client.exchange(code: code, redirectURI: redirectURI, pkce: pkce)
        BopifyLog.auth.info("token exchange succeeded")
        // A signOut() during any of the awaits above already cleared the
        // store; a widened generation means that happened, so this result is
        // stale and must not resurrect the session the user just left.
        guard generation == myGeneration else {
            let currentGeneration = generation
            BopifyLog.auth.notice("stale sign-in discarded generation=\(currentGeneration, privacy: .public) myGeneration=\(myGeneration, privacy: .public)")
            throw PlayerError.authDenied
        }
        try store.save(tokens)
        BopifyLog.auth.debug("saved token set to store")
        self.tokens = tokens
        return tokens
    }

    /// Refreshes ahead of expiry: an expired token silently kills the
    /// Spirc session rather than failing loudly.
    public func validAccessToken() async throws -> String {
        guard let current = tokens ?? restore() else { throw PlayerError.authExpired }
        guard current.needsRefresh() else {
            BopifyLog.auth.debug("using cached access token")
            return current.accessToken
        }
        BopifyLog.auth.debug("access token needs refresh")
        guard let refreshToken = current.refreshToken else {
            BopifyLog.auth.error("no refresh token available")
            throw PlayerError.authExpired
        }
        let myGeneration = generation
        let refreshed = try await client.refresh(refreshToken: refreshToken)
        // Same reentrancy hazard as signIn(): a signOut() during the refresh
        // must not have its result written back over the cleared session.
        guard generation == myGeneration else {
            let currentGeneration = generation
            BopifyLog.auth.notice("stale refresh discarded generation=\(currentGeneration, privacy: .public) myGeneration=\(myGeneration, privacy: .public)")
            throw PlayerError.authExpired
        }
        try store.save(refreshed)
        tokens = refreshed
        BopifyLog.auth.info("token refresh succeeded")
        return refreshed.accessToken
    }

    public func signOut() {
        generation += 1
        BopifyLog.auth.info("signOut")
        do {
            try store.clear()
        } catch {
            let description = String(describing: error)
            BopifyLog.auth.error("failed to clear token store error=\(description, privacy: .public)")
        }
        tokens = nil
    }
}
