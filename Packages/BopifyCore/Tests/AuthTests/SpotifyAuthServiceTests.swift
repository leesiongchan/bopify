import Testing
import Foundation
@testable import BopifyAuth
import BopifyDomain

/// A URLProtocol stub distinct from TokenClientTests' `StubProtocol`: its
/// `handler` is shared mutable state, and Swift Testing runs suites from
/// different types in parallel by default, so reusing that one would race
/// with TokenClientTests' own tests.
final class AuthFlowStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let (status, data) = Self.handler?(request) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class InMemoryTokenStore: TokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: TokenSet?

    func save(_ tokens: TokenSet) throws {
        lock.lock(); defer { lock.unlock() }
        self.tokens = tokens
    }

    func load() -> TokenSet? {
        lock.lock(); defer { lock.unlock() }
        return tokens
    }

    func clear() throws {
        lock.lock(); defer { lock.unlock() }
        tokens = nil
    }
}

@Suite("SpotifyAuthService", .serialized)
struct SpotifyAuthServiceTests {
    private let success = #"""
    {"access_token":"AT","token_type":"Bearer","expires_in":3600,
     "refresh_token":"RT","scope":"streaming"}
    """#

    private func makeClient() -> TokenClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AuthFlowStubProtocol.self]
        return TokenClient(clientID: "client123", session: URLSession(configuration: config))
    }

    /// Drives the real flow end to end: acts as the browser, asserting the
    /// exact scope the user would be asked to approve, then fires the
    /// loopback callback itself so `signIn()` completes instead of hanging.
    @Test func signInRequestsExactlyTheStreamingScopeAndCompletesTheFlow() async throws {
        AuthFlowStubProtocol.handler = { _ in (200, Data(self.success.utf8)) }
        let store = InMemoryTokenStore()
        let service = SpotifyAuthService(
            clientID: "client123",
            client: makeClient(),
            store: store,
            openURL: { url in
                let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
                #expect(query["scope"] == "streaming")
                guard let redirectURI = query["redirect_uri"], let state = query["state"] else { return }
                let callbackURL = URL(string: "\(redirectURI)?code=TESTCODE&state=\(state)")!
                Task { _ = try? await URLSession.shared.data(from: callbackURL) }
            }
        )

        let tokens = try await service.signIn()

        #expect(tokens.accessToken == "AT")
        #expect(tokens.grantedScopes == ["streaming"])
        #expect(store.load()?.accessToken == "AT")
    }
}
