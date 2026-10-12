import Foundation
import os
import BopifyDomain

public enum LibraryClientIDError: Error, Equatable { case invalid }

// Apple documents UserDefaults as thread-safe but the SDK omits the annotation, which blocks passing one to an actor.
extension UserDefaults: @retroactive @unchecked Sendable {}

/// The user's own Spotify Dashboard client for Web API library access. Spotify caps a
/// Development Mode app at five users, so every user registers one; the ID is public, not a secret.
public actor LibraryAuthorization {
    public static let defaultsKey = "library.clientID"

    private let defaults: UserDefaults
    private let makeAuth: @Sendable (String) -> SpotifyAuthService
    private var clientID: String?
    private var auth: SpotifyAuthService?

    public init(defaults: UserDefaults = .standard, makeAuth: @escaping @Sendable (String) -> SpotifyAuthService) {
        self.defaults = defaults
        self.makeAuth = makeAuth
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
        if id == clientID { return id }
        // Detach before awaiting: requests arriving mid-swap fail instead of reaching either client.
        let previous = auth
        auth = nil
        clientID = nil
        // Tokens belong to the client that issued them, and every client shares one Keychain item.
        await previous?.signOut()
        let next = makeAuth(id)
        await next.signOut()
        defaults.set(id, forKey: Self.defaultsKey)
        clientID = id
        auth = next
        BopifyLog.auth.info("library client ID changed")
        return id
    }

    public func authorize(_ scopes: Set<String>) async throws {
        guard let auth else { throw LibraryError.authorizationRequired }
        _ = try await auth.authorizeLibraryScopes(scopes)
    }

    public func validAccessToken(requiredScopes: Set<String>) async throws -> String {
        guard let auth else { throw LibraryError.authorizationRequired }
        return try await auth.validAccessToken(requiredScopes: requiredScopes)
    }

    public func signOut() async { await auth?.signOut() }

    public func cancelPendingWork() async { await auth?.cancelPendingWork() }
}
