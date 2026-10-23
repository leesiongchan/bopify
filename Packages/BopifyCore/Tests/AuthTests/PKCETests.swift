import Testing
import Foundation
@testable import BopifyAuth

@Suite("AuthorizationRequest")
struct AuthorizationRequestTests {
    private let pkce = PKCEPair(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")

    private func components() throws -> [String: String] {
        let request = AuthorizationRequest(
            clientID: "client123",
            redirectURI: "http://127.0.0.1:52341/callback",
            scopes: ["streaming"],
            pkce: pkce,
            state: "state123"
        )
        let parsed = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
        return Dictionary(uniqueKeysWithValues: (parsed.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    @Test func targetsSpotifyAuthorizeEndpoint() throws {
        let request = AuthorizationRequest(clientID: "c", redirectURI: "http://127.0.0.1:1/callback",
                                           scopes: ["streaming"], pkce: pkce, state: "s")
        #expect(request.url.absoluteString.hasPrefix("https://accounts.spotify.com/authorize?"))
    }

    @Test func usesAuthorizationCodeWithS256() throws {
        let q = try components()
        #expect(q["response_type"] == "code")
        #expect(q["code_challenge_method"] == "S256")
        #expect(q["code_challenge"] == pkce.challenge)
    }

    @Test func carriesTheLoopbackRedirectIncludingItsDynamicPort() throws {
        // Registered without a port; the concrete port must still be sent.
        #expect(try components()["redirect_uri"] == "http://127.0.0.1:52341/callback")
    }

    @Test func carriesStateForCSRFProtection() throws {
        #expect(try components()["state"] == "state123")
    }
}
