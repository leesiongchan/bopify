import AppKit
import Foundation
import BopifyDomain

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
        return tokens
    }

    public func signIn() async throws -> TokenSet {
        generation += 1
        let myGeneration = generation
        let pkce = PKCEPair.random()
        let state = UUID().uuidString
        let listener = LoopbackCallbackListener(expectedState: state)
        let port = try await listener.start()
        defer { Task { await listener.stop() } }

        let redirectURI = "http://127.0.0.1:\(port)/callback"
        let request = AuthorizationRequest(clientID: clientID, redirectURI: redirectURI,
                                           scopes: ["streaming"], pkce: pkce, state: state)
        openURL(request.url)

        let code: String
        do { code = try await listener.waitForCallback() }
        catch CallbackError.accessDenied { throw PlayerError.authDenied }
        catch { throw PlayerError.invalidCallback }

        let tokens = try await client.exchange(code: code, redirectURI: redirectURI, pkce: pkce)
        // A signOut() during any of the awaits above already cleared the
        // store; a widened generation means that happened, so this result is
        // stale and must not resurrect the session the user just left.
        guard generation == myGeneration else { throw PlayerError.authDenied }
        try store.save(tokens)
        self.tokens = tokens
        return tokens
    }

    /// Refreshes ahead of expiry: an expired token silently kills the
    /// Spirc session rather than failing loudly.
    public func validAccessToken() async throws -> String {
        guard let current = tokens ?? restore() else { throw PlayerError.authExpired }
        guard current.needsRefresh() else { return current.accessToken }
        guard let refreshToken = current.refreshToken else { throw PlayerError.authExpired }
        let myGeneration = generation
        let refreshed = try await client.refresh(refreshToken: refreshToken)
        // Same reentrancy hazard as signIn(): a signOut() during the refresh
        // must not have its result written back over the cleared session.
        guard generation == myGeneration else { throw PlayerError.authExpired }
        try store.save(refreshed)
        tokens = refreshed
        return refreshed.accessToken
    }

    public func signOut() {
        generation += 1
        try? store.clear()
        tokens = nil
    }
}
