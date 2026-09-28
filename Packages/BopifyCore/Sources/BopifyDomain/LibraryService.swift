public enum LibraryError: Error, Equatable, Sendable {
    case authorizationRequired, forbidden, invalidResponse, unavailable
    case quotaExceeded(retryAfterSeconds: Int?)
    case rateLimited(retryAfterSeconds: Int?)
}

public protocol LibraryService: Sendable {
    func savedState(for uri: SpotifyURI) async throws -> Bool
    func save(_ uri: SpotifyURI) async throws
    func remove(_ uri: SpotifyURI) async throws
}
