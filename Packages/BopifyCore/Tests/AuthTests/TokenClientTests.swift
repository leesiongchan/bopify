import Testing
import Foundation
@testable import BopifyAuth
import BopifyDomain

final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var lastBody: String?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        // URLSession moves the body to a stream; read it back for assertions.
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(contentsOf: buffer[0..<read])
            }
            stream.close()
            Self.lastBody = String(data: data, encoding: .utf8)
        }
        let (status, data) = Self.handler?(request) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite("TokenClient", .serialized)
struct TokenClientTests {
    private func makeClient() -> TokenClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return TokenClient(clientID: "client123", session: URLSession(configuration: config))
    }

    private let success = #"""
    {"access_token":"AT","token_type":"Bearer","expires_in":3600,
     "refresh_token":"RT","scope":"streaming"}
    """#

    @Test func exchangesAuthorizationCodeForTokens() async throws {
        StubProtocol.handler = { _ in (200, Data(self.success.utf8)) }
        let tokens = try await makeClient().exchange(
            code: "CODE", redirectURI: "http://127.0.0.1:5000/callback",
            pkce: PKCEPair(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"))

        #expect(tokens.accessToken == "AT")
        #expect(tokens.refreshToken == "RT")
        #expect(tokens.grantedScopes == ["streaming"])
        #expect(tokens.expiresAt > Date())
    }

    @Test func sendsPKCEVerifierAndClientIDButNoSecret() async throws {
        StubProtocol.handler = { _ in (200, Data(self.success.utf8)) }
        _ = try await makeClient().exchange(
            code: "CODE", redirectURI: "http://127.0.0.1:5000/callback",
            pkce: PKCEPair(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"))

        let body = try #require(StubProtocol.lastBody)
        #expect(body.contains("grant_type=authorization_code"))
        #expect(body.contains("code_verifier=dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"))
        #expect(body.contains("client_id=client123"))
        #expect(!body.contains("client_secret"))
    }

    @Test func keepsTheExistingRefreshTokenWhenTheResponseOmitsOne() async throws {
        StubProtocol.handler = { _ in
            (200, Data(#"{"access_token":"AT2","token_type":"Bearer","expires_in":3600,"scope":"streaming"}"#.utf8))
        }
        let tokens = try await makeClient().refresh(refreshToken: "OLD_RT")
        // Spotify: "When a refresh token is not returned, continue using
        // the existing token."
        #expect(tokens.refreshToken == "OLD_RT")
        #expect(tokens.accessToken == "AT2")
    }

    @Test func mapsInvalidGrantToAuthExpired() async {
        StubProtocol.handler = { _ in (400, Data(#"{"error":"invalid_grant"}"#.utf8)) }
        await #expect(throws: PlayerError.authExpired) {
            _ = try await makeClient().refresh(refreshToken: "DEAD")
        }
    }

    @Test func unknownOAuthFailureDoesNotMisidentifyRevokedCredentials() async {
        StubProtocol.handler = { _ in (400, Data(#"{"error":"invalid_client"}"#.utf8)) }
        await #expect(throws: PlayerError.unknown) { _ = try await makeClient().refresh(refreshToken: "RT") }
    }

    @Test func throttlingIsRetryable() async {
        StubProtocol.handler = { _ in (429, Data(#"{"error":"temporarily_unavailable"}"#.utf8)) }
        await #expect(throws: PlayerError.networkUnavailable) { _ = try await makeClient().refresh(refreshToken: "RT") }
    }

    @Test func malformedSuccessIsUnknown() async {
        StubProtocol.handler = { _ in (200, Data("{}".utf8)) }
        await #expect(throws: PlayerError.unknown) { _ = try await makeClient().refresh(refreshToken: "RT") }
    }

    @Test func cancelledRefreshRemainsCancellation() async {
        let task = Task { () throws -> TokenSet in
            try Task.checkCancellation()
            return try await makeClient().refresh(refreshToken: "RT")
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test func mapsServerFailureToNetworkUnavailable() async {
        StubProtocol.handler = { _ in (503, Data()) }
        await #expect(throws: PlayerError.networkUnavailable) {
            _ = try await makeClient().refresh(refreshToken: "RT")
        }
    }
    @Test func omittedRefreshScopePreservesExistingGrant() async throws {
        StubProtocol.handler = { _ in (200, Data(#"{"access_token":"NEW_FAKE","expires_in":3600}"#.utf8)) }
        let tokens = try await makeClient().refresh(refreshToken: "OLD_FAKE", grantedScopes: ["streaming", "user-library-read"])
        #expect(tokens.grantedScopes == ["streaming", "user-library-read"])
    }

    @Test func explicitRefreshScopeReplacesExistingGrant() async throws {
        StubProtocol.handler = { _ in (200, Data(#"{"access_token":"NEW_FAKE","expires_in":3600,"scope":"streaming"}"#.utf8)) }
        let tokens = try await makeClient().refresh(refreshToken: "OLD_FAKE", grantedScopes: ["streaming", "user-library-read"])
        #expect(tokens.grantedScopes == ["streaming"])
    }

}
