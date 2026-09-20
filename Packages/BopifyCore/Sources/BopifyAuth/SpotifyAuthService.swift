import AppKit
import Foundation
import BopifyDomain

public actor SpotifyAuthService {
    private let clientID: String
    private let client: TokenClient
    private let store: any TokenStoring
    private let openURL: @Sendable (URL) -> Void
    private var tokens: TokenSet?

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
        let refreshed = try await client.refresh(refreshToken: refreshToken)
        try store.save(refreshed)
        tokens = refreshed
        return refreshed.accessToken
    }

    public func signOut() {
        try? store.clear()
        tokens = nil
    }
}
