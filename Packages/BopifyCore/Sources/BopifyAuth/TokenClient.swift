import Foundation
import BopifyDomain

public struct TokenClient: Sendable {
    private let clientID: String
    private let session: URLSession
    private static let endpoint = URL(string: "https://accounts.spotify.com/api/token")!

    public init(clientID: String, session: URLSession = .shared) {
        self.clientID = clientID
        self.session = session
    }

    public func exchange(code: String, redirectURI: String, pkce: PKCEPair) async throws -> TokenSet {
        try await post([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": pkce.verifier,
        ], fallbackRefreshToken: nil)
    }

    public func refresh(refreshToken: String) async throws -> TokenSet {
        try await post([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ], fallbackRefreshToken: refreshToken)
    }

    private struct Response: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int
        let scope: String?
    }

    private func post(_ fields: [String: String], fallbackRefreshToken: String?) async throws -> TokenSet {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(fields.map { "\($0.key)=\(Self.escape($0.value))" }.joined(separator: "&").utf8)

        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) }
        catch { throw PlayerError.networkUnavailable }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200:
            guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else { throw PlayerError.unknown }
            return TokenSet(
                accessToken: decoded.access_token,
                // Spotify does not always rotate refresh tokens; keep the old
                // one when the response omits it.
                refreshToken: decoded.refresh_token ?? fallbackRefreshToken,
                expiresAt: Date().addingTimeInterval(TimeInterval(decoded.expires_in)),
                grantedScopes: Set(decoded.scope?.split(separator: " ").map(String.init) ?? [])
            )
        case 400, 401:
            throw PlayerError.authExpired
        default:
            throw PlayerError.networkUnavailable
        }
    }

    private static func escape(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
