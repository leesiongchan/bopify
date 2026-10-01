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
    private let callbackPort: UInt16?
    private let callbackPath: String
    private let openURL: @Sendable (URL) -> Void
    private var tokens: TokenSet?
    // Sign-out and new consent invalidate suspended work before it can persist credentials.
    private var generation = 0
    private var refresh: (id: UUID, generation: Int, task: Task<TokenSet, Error>)?
    private var activeListener: LoopbackCallbackListener?

    public init(
        clientID: String,
        client: TokenClient? = nil,
        store: any TokenStoring = KeychainTokenStore(),
        callbackPort: UInt16? = nil,
        callbackPath: String = "/login",
        openURL: @Sendable @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.clientID = clientID
        self.client = client ?? TokenClient(clientID: clientID)
        self.store = store
        self.callbackPort = callbackPort
        self.callbackPath = callbackPath
        self.openURL = openURL
    }

    public func restore() -> TokenSet? {
        tokens = store.load()
        let found = tokens != nil
        BopifyLog.auth.debug("restore found=\(found, privacy: .public)")
        return tokens
    }

    public func signIn() async throws -> TokenSet {
        try await authorize(scopes: ["streaming"], validateGrant: false)
    }

    public func authorizeLibraryScopes(_ scopes: Set<String>) async throws -> TokenSet {
        let libraryScopes: Set<String> = ["user-library-read", "user-library-modify", "user-read-recently-played", "user-top-read"]
        guard !scopes.isEmpty, scopes.isSubset(of: libraryScopes) else { throw LibraryError.authorizationRequired }
        let existing = (tokens ?? restore())?.grantedScopes.intersection(libraryScopes) ?? []
        let required = existing.union(scopes)
        return try await authorize(scopes: required, validateGrant: true)
    }

    private func authorize(scopes: Set<String>, validateGrant: Bool) async throws -> TokenSet {
        refresh?.task.cancel()
        refresh = nil
        generation += 1
        let myGeneration = generation
        BopifyLog.auth.info("signIn starting generation=\(myGeneration, privacy: .public)")
        let previousListener = activeListener
        activeListener = nil
        if let previousListener { await previousListener.stop() }
        guard generation == myGeneration else { throw PlayerError.authDenied }
        let pkce = PKCEPair.random()
        let state = UUID().uuidString
        let listener = LoopbackCallbackListener(expectedState: state)
        activeListener = listener
        let port: Int
        do { port = try await listener.start(port: callbackPort) }
        catch {
            if activeListener === listener { activeListener = nil }
            if generation != myGeneration { throw PlayerError.authDenied }
            throw error
        }
        guard generation == myGeneration else {
            await stopAuthorization(listener)
            throw PlayerError.authDenied
        }
        BopifyLog.auth.debug("callback listener bound port=\(port, privacy: .public)")

        let redirectURI = "http://127.0.0.1:\(port)\(callbackPath)"
        let request = AuthorizationRequest(clientID: clientID, redirectURI: redirectURI,
                                           scopes: scopes.sorted(), pkce: pkce, state: state)
        openURL(request.url)
        BopifyLog.auth.info("opened system browser for authorization")

        let code: String
        do { code = try await listener.waitForCallback() }
        catch CallbackError.accessDenied {
            await stopAuthorization(listener)
            BopifyLog.auth.notice("user declined consent")
            throw PlayerError.authDenied
        }
        catch {
            await stopAuthorization(listener)
            if generation != myGeneration { throw PlayerError.authDenied }
            let description = String(describing: error)
            BopifyLog.auth.error("callback wait failed error=\(description, privacy: .public)")
            throw PlayerError.invalidCallback
        }
        await stopAuthorization(listener)

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
        if validateGrant && !scopes.isSubset(of: tokens.grantedScopes) {
            throw LibraryError.authorizationRequired
        }
        try store.save(tokens)
        BopifyLog.auth.debug("saved token set to store")
        self.tokens = tokens
        return tokens
    }

    private func stopAuthorization(_ listener: LoopbackCallbackListener) async {
        await listener.stop()
        if activeListener === listener { activeListener = nil }
    }

    public func validAccessToken() async throws -> String {
        try await validAccessToken(requiredScopes: [])
    }

    public func validAccessToken(requiredScopes: Set<String>) async throws -> String {
        guard let current = tokens ?? restore() else {
            if !requiredScopes.isEmpty { throw LibraryError.authorizationRequired }
            throw PlayerError.authExpired
        }
        guard requiredScopes.isSubset(of: current.grantedScopes) else { throw LibraryError.authorizationRequired }
        if !current.needsRefresh() { return current.accessToken }
        guard let refreshToken = current.refreshToken else { throw PlayerError.authExpired }
        let myGeneration = generation
        let pending: (id: UUID, generation: Int, task: Task<TokenSet, Error>)
        if let refresh, refresh.generation == myGeneration {
            pending = refresh
        } else {
            let task = Task { [client] in
                try await client.refresh(refreshToken: refreshToken, grantedScopes: current.grantedScopes)
            }
            pending = (UUID(), myGeneration, task)
            refresh = pending
            BopifyLog.auth.debug("token refresh started")
        }
        defer { if refresh?.id == pending.id { refresh = nil } }
        let refreshed = try await pending.task.value
        guard generation == myGeneration else { throw PlayerError.authExpired }
        // Only the first waiter writes; other waiters consume the same result.
        if refresh?.id == pending.id {
            try store.save(refreshed)
            tokens = refreshed
            BopifyLog.auth.info("token refresh succeeded")
        }
        try Task.checkCancellation()
        guard requiredScopes.isSubset(of: refreshed.grantedScopes) else { throw LibraryError.authorizationRequired }
        return refreshed.accessToken
    }

    public func signOut() async {
        generation += 1
        refresh?.task.cancel()
        refresh = nil
        BopifyLog.auth.info("signOut")
        do {
            try store.clear()
        } catch {
            let description = String(describing: error)
            BopifyLog.auth.error("failed to clear token store error=\(description, privacy: .public)")
        }
        tokens = nil
        let listener = activeListener
        activeListener = nil
        if let listener { await listener.stop() }
    }
}
