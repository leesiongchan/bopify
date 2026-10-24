import Foundation
import os
import BopifyDomain

public enum LibraryClientIDError: Error, Equatable { case invalid }

/// The user's own Spotify Dashboard client for Web API library access. Spotify caps a
/// Development Mode app at five users, so every user registers one; the ID is public, not a secret.
public actor LibraryAuthorization {
    public static let defaultsKey = "library.clientID"
    public static let requiredScopes: Set<String> = [
        "user-library-read", "user-library-modify", "user-read-recently-played", "user-top-read",
        "playlist-read-private", "playlist-read-collaborative", "user-follow-read"
    ]

    private let defaults: UserDefaults
    private let makeAuth: @Sendable (String) -> SpotifyAuthService
    private let orphanedStore: (any TokenStoring)?
    private let logoutIntent: LogoutIntentStore?
    private var clientID: String?
    private var auth: SpotifyAuthService?
    private var clientChange: (id: UUID, task: Task<String, Error>)?

    /// `suiteName` nil means `.standard`; the defaults are built here because `UserDefaults` is not `Sendable`.
    public init(suiteName: String? = nil, orphanedStore: (any TokenStoring)? = nil,
                logoutIntent: LogoutIntentStore? = nil, makeAuth: @escaping @Sendable (String) -> SpotifyAuthService) {
        let defaults = suiteName.map { UserDefaults(suiteName: $0)! } ?? .standard
        self.defaults = defaults
        self.makeAuth = makeAuth
        self.orphanedStore = orphanedStore
        self.logoutIntent = logoutIntent
        clientID = Self.storedClientID(in: defaults)
        auth = clientID.map(makeAuth)
    }

    /// Spotify client IDs are 32 lowercase hex characters; pasted input often carries case or whitespace.
    public static func normalized(_ raw: String) -> String? {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hex = Set("0123456789abcdef")
        return id.count == 32 && id.allSatisfy(hex.contains) ? id : nil
    }

    public static func storedClientID(in defaults: UserDefaults) -> String? {
        defaults.string(forKey: defaultsKey).flatMap(normalized)
    }

    public func setClientID(_ raw: String) async throws -> String {
        guard let id = Self.normalized(raw) else { throw LibraryClientIDError.invalid }
        let previous = clientChange?.task
        let changeID = UUID()
        // Actor isolation does not serialize a change across credential-removal awaits.
        let task = Task {
            _ = await previous?.result
            return try await replaceClientID(id)
        }
        clientChange = (changeID, task)
        defer { if clientChange?.id == changeID { clientChange = nil } }
        return try await task.value
    }

    private func replaceClientID(_ id: String) async throws -> String {
        if id == clientID { return id }
        // Detach before awaiting: requests arriving mid-swap fail instead of reaching either client.
        let previous = auth, previousID = clientID
        auth = nil
        clientID = nil
        // Tokens belong to the client that issued them, and every client shares one Keychain item.
        do {
            try await previous?.signOutAndClearCredentials()
            let next = makeAuth(id)
            try await next.signOutAndClearCredentials()
            defaults.set(id, forKey: Self.defaultsKey)
            clientID = id
            auth = next
        } catch {
            auth = previous
            clientID = previousID
            BopifyLog.auth.error("library client change blocked by credential removal failure")
            throw error
        }
        BopifyLog.auth.info("library client ID changed")
        return id
    }

    public func authorize() async throws {
        guard let auth else { throw LibraryError.authorizationRequired }
        _ = try await auth.authorizeLibrary()
    }

    public func validAccessToken(requiredScopes: Set<String>) async throws -> String {
        guard let auth else { throw LibraryError.authorizationRequired }
        return try await auth.validAccessToken(requiredScopes: requiredScopes)
    }

    public func signOut() async throws {
        if let auth { try await auth.signOut(); return }
        guard let orphanedStore else { throw PlayerError.credentialCleanupRequired }
        do { try logoutIntent?.begin([.library]) }
        catch {
            BopifyLog.auth.error("library cleanup intent could not be persisted; deletion deferred")
            throw PlayerError.credentialCleanupNotRecorded
        }
        do {
            try orphanedStore.clear()
            try logoutIntent?.complete(.library)
        } catch {
            BopifyLog.auth.error("orphaned library credential cleanup failed")
            throw PlayerError.credentialCleanupRequired
        }
    }

    public func cancelPendingWork() async { await auth?.cancelPendingWork() }
}
