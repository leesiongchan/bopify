import Foundation

public enum AuthState: Hashable, Sendable {
    case signedOut, authenticating, signedIn, refreshing, needsReauthentication
    case error(PlayerError)
}

public struct TokenSet: Hashable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date
    public let grantedScopes: Set<String>

    public init(accessToken: String, refreshToken: String?, expiresAt: Date, grantedScopes: Set<String>) {
        self.accessToken = accessToken; self.refreshToken = refreshToken
        self.expiresAt = expiresAt; self.grantedScopes = grantedScopes
    }

    /// Refresh early: an expired token silently kills the Spirc session.
    public func needsRefresh(now: Date = .now, margin: TimeInterval = 300) -> Bool {
        now.addingTimeInterval(margin) >= expiresAt
    }
}
