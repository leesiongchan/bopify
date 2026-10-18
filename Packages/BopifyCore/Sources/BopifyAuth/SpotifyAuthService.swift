import AppKit
import Foundation
import os
import BopifyDomain

/// librespot's first-party Spotify client ID, and the only one that can
/// reach the streaming endpoint -- a Developer Dashboard ID is rejected
/// by login5 with HTTP 400.
/// Spotify may revoke it at any time, which is the realistic failure
/// mode for this app; keeping it in one place makes that a one-line fix.
public let librespotClientID = "65b708073fc0480ea92a077233ca87bd"

public actor SpotifyAuthService {
    private let clientID: String
    private let client: TokenClient
    private let store: any TokenStoring
    private let logoutIntent: LogoutIntentStore?
    private let credentialNamespace: CredentialNamespace
    private var logoutRequested = false
    private let callbackPort: UInt16?
    private let callbackPath: String
    private let openURL: @Sendable (URL) -> Void
    private var tokens: TokenSet?
    // Sign-out and new consent invalidate suspended work before it can persist credentials.
    private var generation = 0
    private var refresh: (id: UUID, generation: Int, task: Task<TokenSet, Error>)?
    private var pendingRefresh: (generation: Int, tokens: TokenSet)?
    private var activeListener: LoopbackCallbackListener?

    public init(
        clientID: String,
        client: TokenClient? = nil,
        store: any TokenStoring = KeychainTokenStore(),
        logoutIntent: LogoutIntentStore? = nil,
        credentialNamespace: CredentialNamespace = .playback,
        callbackPort: UInt16? = nil,
        callbackPath: String = "/login",
        openURL: @Sendable @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.clientID = clientID
        self.client = client ?? TokenClient(clientID: clientID)
        self.store = store
        self.logoutIntent = logoutIntent
        self.credentialNamespace = credentialNamespace
        self.callbackPort = callbackPort
        self.callbackPath = callbackPath
        self.openURL = openURL
    }

    public func restore() throws -> TokenSet? {
        try checkCleanupIntent()
        guard !logoutRequested else { return nil }
        do { tokens = try store.load() }
        catch KeychainError.accessDenied { throw PlayerError.credentialAccessDenied }
        catch KeychainError.corrupt { throw PlayerError.credentialCorrupt }
        catch { throw PlayerError.credentialUnavailable }
        let found = tokens != nil
        BopifyLog.auth.debug("restore found=\(found, privacy: .public)")
        return tokens
    }

    public func signIn() async throws -> TokenSet {
        try Task.checkCancellation()
        try await prepareForConsent()
        return try await authorize(scopes: ["streaming"], validateGrant: false)
    }

    public func authorizeLibraryScopes(_ scopes: Set<String>) async throws -> TokenSet {
        try Task.checkCancellation()
        let libraryScopes: Set<String> = ["user-library-read", "user-library-modify", "user-read-recently-played", "user-top-read",
                                          "playlist-read-private", "playlist-read-collaborative"]
        guard scopes.isSubset(of: libraryScopes) else { throw LibraryError.authorizationRequired }
        try await prepareForConsent()
        let existing: Set<String>
        do { existing = (try tokens ?? restore())?.grantedScopes.intersection(libraryScopes) ?? [] }
        catch PlayerError.credentialCorrupt {
            existing = []
            BopifyLog.auth.notice("explicit library consent will replace a corrupt grant")
        }
        let required = existing.union(scopes)
        return try await authorize(scopes: required, validateGrant: true)
    }

    private func authorize(scopes: Set<String>, validateGrant: Bool) async throws -> TokenSet {
        try Task.checkCancellation()
        refresh?.task.cancel()
        refresh = nil
        generation += 1
        pendingRefresh = nil
        let myGeneration = generation
        BopifyLog.auth.info("signIn starting generation=\(myGeneration, privacy: .public)")
        let previousListener = activeListener
        activeListener = nil
        if let previousListener { await previousListener.stop() }
        try Task.checkCancellation()
        guard generation == myGeneration else { throw PlayerError.authDenied }
        let state = UUID().uuidString
        let listener = LoopbackCallbackListener(expectedState: state, expectedPath: callbackPath)
        return try await withTaskCancellationHandler {
            do { return try await authorize(scopes: scopes, validateGrant: validateGrant, generation: myGeneration, listener: listener, state: state) }
            catch {
                await stopAuthorization(listener)
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
        } onCancel: {
            Task { await listener.stop() }
        }
    }

    private func authorize(scopes: Set<String>, validateGrant: Bool, generation myGeneration: Int,
                           listener: LoopbackCallbackListener, state: String) async throws -> TokenSet {
        let pkce = PKCEPair.random()
        activeListener = listener
        let port: Int
        do { port = try await listener.start(port: callbackPort) }
        catch {
            if activeListener === listener { activeListener = nil }
            if generation != myGeneration { throw PlayerError.authDenied }
            throw error
        }
        try Task.checkCancellation()
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
            if Task.isCancelled { throw CancellationError() }
            if generation != myGeneration { throw PlayerError.authDenied }
            let description = String(describing: error)
            BopifyLog.auth.error("callback wait failed error=\(description, privacy: .public)")
            throw PlayerError.invalidCallback
        }
        await stopAuthorization(listener)
        try Task.checkCancellation()

        let tokens = try await client.exchange(code: code, redirectURI: redirectURI, pkce: pkce)
        try Task.checkCancellation()
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
        try persist(tokens)
        // Refreshes of the previous grant can start while consent waits in the browser.
        generation += 1
        refresh?.task.cancel()
        refresh = nil
        pendingRefresh = nil
        self.tokens = tokens
        BopifyLog.auth.info("new authorization grant persisted; previous refresh invalidated")
        return tokens
    }

    private func stopAuthorization(_ listener: LoopbackCallbackListener) async {
        await listener.stop()
        if activeListener === listener { activeListener = nil }
    }

    public func validAccessToken() async throws -> String {
        try await validAccessToken(requiredScopes: [])
    }

    public func validAccessToken(rejecting rejectedAccessToken: String) async throws -> String {
        try await validAccessToken(requiredScopes: [], rejecting: rejectedAccessToken)
    }

    public func validAccessToken(requiredScopes: Set<String>) async throws -> String {
        try await validAccessToken(requiredScopes: requiredScopes, rejecting: nil)
    }

    private func validAccessToken(requiredScopes: Set<String>, rejecting rejectedAccessToken: String?) async throws -> String {
        try checkCleanupIntent()
        guard !logoutRequested else { throw PlayerError.authExpired }
        guard let current = try tokens ?? restore() else {
            if !requiredScopes.isEmpty { throw LibraryError.authorizationRequired }
            throw PlayerError.authExpired
        }
        guard requiredScopes.isSubset(of: current.grantedScopes) else { throw LibraryError.authorizationRequired }
        if pendingRefresh == nil, !current.needsRefresh(), current.accessToken != rejectedAccessToken { return current.accessToken }
        guard let refreshToken = current.refreshToken else { throw PlayerError.authExpired }
        let myGeneration = generation
        let pending: (id: UUID, generation: Int, task: Task<TokenSet, Error>)
        if let refresh, refresh.generation == myGeneration {
            pending = refresh
        } else {
            let task = Task {
                try await self.refreshAndPersist(refreshToken: refreshToken, scopes: current.grantedScopes, generation: myGeneration)
            }
            pending = (UUID(), myGeneration, task)
            refresh = pending
            BopifyLog.auth.debug("token refresh started")
        }
        defer { if refresh?.id == pending.id { refresh = nil } }
        let refreshed = try await pending.task.value
        guard generation == myGeneration else { throw PlayerError.authExpired }
        try Task.checkCancellation()
        guard requiredScopes.isSubset(of: refreshed.grantedScopes) else { throw LibraryError.authorizationRequired }
        return refreshed.accessToken
    }

    private func persist(_ tokens: TokenSet) throws {
        try checkCleanupIntent()
        do { try store.save(tokens) }
        catch {
            BopifyLog.auth.error("credential persistence failed")
            throw PlayerError.credentialSaveFailed
        }
    }

    private func refreshAndPersist(refreshToken: String, scopes: Set<String>, generation mine: Int) async throws -> TokenSet {
        let refreshed: TokenSet
        if let pendingRefresh, pendingRefresh.generation == mine {
            let pending = pendingRefresh.tokens
            try persistRefresh(pending, generation: mine)
            if !pending.needsRefresh() { return pending }
            guard let rotated = pending.refreshToken else { throw PlayerError.authExpired }
            refreshed = try await client.refresh(refreshToken: rotated, grantedScopes: pending.grantedScopes)
        } else {
            refreshed = try await client.refresh(refreshToken: refreshToken, grantedScopes: scopes)
        }
        try persistRefresh(refreshed, generation: mine)
        return refreshed
    }

    private func persistRefresh(_ refreshed: TokenSet, generation mine: Int) throws {
        guard generation == mine else { throw PlayerError.authExpired }
        try Task.checkCancellation()
        // A rotated refresh grant must survive a temporary save failure for manual retry.
        pendingRefresh = (mine, refreshed)
        try persist(refreshed)
        pendingRefresh = nil
        tokens = refreshed
        BopifyLog.auth.info("token refresh persisted")
    }

    public func cancelPendingWork() async {
        generation += 1
        pendingRefresh = nil
        refresh?.task.cancel()
        refresh = nil
        let listener = activeListener
        activeListener = nil
        if let listener { await listener.stop() }
        BopifyLog.auth.debug("pending authorization cancelled")
    }

    public func signOut() async throws {
        logoutRequested = true
        do { try logoutIntent?.begin([credentialNamespace]) }
        catch {
            tokens = nil
            await cancelPendingWork()
            BopifyLog.auth.error("credential cleanup intent could not be persisted; deletion deferred")
            throw PlayerError.credentialCleanupNotRecorded
        }
        do {
            try await signOutAndClearCredentials()
            try logoutIntent?.complete(credentialNamespace)
        } catch {
            BopifyLog.auth.error("sign-out requires credential cleanup retry")
            throw PlayerError.credentialCleanupRequired
        }
    }

    private func checkCleanupIntent() throws {
        do {
            if try logoutIntent?.isPending(credentialNamespace) == true {
                throw PlayerError.credentialCleanupRequired
            }
        } catch { throw PlayerError.credentialCleanupRequired }
    }

    private func prepareForConsent() async throws {
        let pending: Bool
        do { pending = try logoutIntent?.isPending(credentialNamespace) ?? false }
        catch { throw PlayerError.credentialCleanupRequired }
        if logoutRequested || pending {
            try await signOut()
            BopifyLog.auth.info("credential cleanup completed before explicit consent")
        }
        logoutRequested = false
    }

    /// Client changes must confirm that the previous client's stored grant is gone.
    public func signOutAndClearCredentials() async throws {
        generation += 1
        pendingRefresh = nil
        refresh?.task.cancel()
        refresh = nil
        tokens = nil
        BopifyLog.auth.info("signOut")
        let removal = Result { try store.clear() }
        let listener = activeListener
        activeListener = nil
        if let listener { await listener.stop() }
        do { try removal.get() }
        catch {
            BopifyLog.auth.error("stored credential removal failed")
            throw PlayerError.credentialUnavailable
        }
    }
}
