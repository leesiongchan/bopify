import AppAuthCore
import Foundation

public struct AuthorizationRequest: Sendable {
    public let url: URL

    public init(clientID: String, redirectURI: String, scopes: [String], pkce: PKCEPair, state: String) {
        url = OIDAuthorizationRequest(configuration: spotifyOAuthConfiguration(), clientId: clientID,
            clientSecret: nil, scope: scopes.joined(separator: " "), redirectURL: URL(string: redirectURI)!,
            responseType: OIDResponseTypeCode, state: state, nonce: nil, codeVerifier: pkce.verifier,
            codeChallenge: pkce.challenge, codeChallengeMethod: OIDOAuthorizationRequestCodeChallengeMethodS256,
            additionalParameters: nil).authorizationRequestURL()
    }
}

func spotifyOAuthConfiguration() -> OIDServiceConfiguration {
    OIDServiceConfiguration(authorizationEndpoint: URL(string: "https://accounts.spotify.com/authorize")!,
                            tokenEndpoint: URL(string: "https://accounts.spotify.com/api/token")!)
}
