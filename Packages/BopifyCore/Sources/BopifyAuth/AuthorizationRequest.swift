import Foundation

public struct AuthorizationRequest: Sendable {
    public let url: URL

    public init(clientID: String, redirectURI: String, scopes: [String], pkce: PKCEPair, state: String) {
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "scope", value: scopes.joined(separator: " ")),
            .init(name: "state", value: state),
        ]
        self.url = components.url!
    }
}
