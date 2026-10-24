import AppAuthCore
import Foundation
import BopifyDomain

public struct TokenClient: Sendable {
    private let clientID: String
    private let session: URLSession

    public init(clientID: String, session: URLSession = .shared) {
        self.clientID = clientID
        self.session = session
    }

    public func exchange(code: String, redirectURI: String, pkce: PKCEPair) async throws -> TokenSet {
        let request = OIDTokenRequest(configuration: spotifyOAuthConfiguration(), grantType: OIDGrantTypeAuthorizationCode,
            authorizationCode: code, redirectURL: URL(string: redirectURI), clientID: clientID, clientSecret: nil,
            scope: nil, refreshToken: nil, codeVerifier: pkce.verifier, additionalParameters: nil)
        return try await post(request, fallbackRefreshToken: nil)
    }

    public func refresh(refreshToken: String, grantedScopes: Set<String> = []) async throws -> TokenSet {
        let request = OIDTokenRequest(configuration: spotifyOAuthConfiguration(), grantType: OIDGrantTypeRefreshToken,
            authorizationCode: nil, redirectURL: nil, clientID: clientID, clientSecret: nil,
            scope: nil, refreshToken: refreshToken, codeVerifier: nil, additionalParameters: nil)
        return try await post(request, fallbackRefreshToken: refreshToken, fallbackScopes: grantedScopes)
    }

    private struct Response: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int
        let scope: String?
        let token_type: String?
    }

    private func post(_ request: OIDTokenRequest, fallbackRefreshToken: String?, fallbackScopes: Set<String> = []) async throws -> TokenSet {
        try Task.checkCancellation()
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request.urlRequest()) }
        catch is CancellationError { throw CancellationError() }
        catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw PlayerError.networkUnavailable
        }
        try Task.checkCancellation()
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200:
            guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
                  !decoded.access_token.isEmpty,
                  decoded.refresh_token?.isEmpty != true,
                  decoded.expires_in >= 0,
                  decoded.token_type == nil || decoded.token_type?.caseInsensitiveCompare("Bearer") == .orderedSame else {
                throw PlayerError.unknown
            }
            return TokenSet(accessToken: decoded.access_token,
                refreshToken: decoded.refresh_token ?? fallbackRefreshToken,
                expiresAt: Date().addingTimeInterval(TimeInterval(decoded.expires_in)),
                grantedScopes: decoded.scope.map { Set($0.split(separator: " ").map(String.init)) } ?? fallbackScopes)
        case 429, 500...599:
            throw PlayerError.networkUnavailable
        default:
            struct OAuthFailure: Decodable { let error: String }
            let failure = try? JSONDecoder().decode(OAuthFailure.self, from: data)
            if failure?.error == "invalid_grant" { throw PlayerError.authExpired }
            throw PlayerError.unknown
        }
    }
}
