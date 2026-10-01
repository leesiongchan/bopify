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

/// Late-binds a reference the `openURL` closure needs but that doesn't exist
/// yet when the closure is constructed (the service being built takes the
/// closure as an init argument). Set once, read only after that, from a
/// closure that only ever fires once `signIn()` is called.
final class LateBinding<Value>: @unchecked Sendable {
    var value: Value?
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
    private let librarySuccess = #"{"access_token":"LIBRARY","token_type":"Bearer","expires_in":3600,"refresh_token":"LIBRARY_RT","scope":"user-library-read"}"#
    private let success = #"""
    {"access_token":"AT","token_type":"Bearer","expires_in":3600,
     "refresh_token":"RT","scope":"streaming"}
    """#

    private func makeClient() -> TokenClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AuthFlowStubProtocol.self]
        return TokenClient(clientID: "client123", session: URLSession(configuration: config))
    }

    @Test func libraryConsentStartsWithoutPlaybackGrant() async throws {
        AuthFlowStubProtocol.handler = { _ in (200, Data(self.librarySuccess.utf8)) }
        let store = InMemoryTokenStore()
        let service = SpotifyAuthService(clientID: "25bbd3bacca4412b80f17b892072af71", client: makeClient(), store: store, openURL: { url in
            let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
            #expect(query["client_id"] == "25bbd3bacca4412b80f17b892072af71")
            #expect(query["scope"] == "user-library-read")
            #expect(URL(string: query["redirect_uri"]!)?.path == "/login")
            let callback = URL(string: "\(query["redirect_uri"]!)?code=TESTCODE&state=\(query["state"]!)")!
            Task { _ = try? await URLSession.shared.data(from: callback) }
        })
        let token = try await service.authorizeLibraryScopes(["user-library-read"])
        #expect(token.grantedScopes == ["user-library-read"])
        #expect(store.load()?.accessToken == "LIBRARY")
    }

    @Test func libraryConsentUsesTheRegisteredFixedCallback() async throws {
        AuthFlowStubProtocol.handler = { _ in (200, Data(self.librarySuccess.utf8)) }
        let reserved = LoopbackCallbackListener(expectedState: "unused")
        let port = try await reserved.start()
        await reserved.stop()
        let callback = "http://127.0.0.1:\(port)/callback"
        let service = SpotifyAuthService(clientID: "dashboard", client: makeClient(), store: InMemoryTokenStore(),
                                         callbackPort: UInt16(port), callbackPath: "/callback", openURL: { url in
            let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
            #expect(query["redirect_uri"] == callback)
            let response = URL(string: "\(callback)?code=TESTCODE&state=\(query["state"]!)")!
            Task { _ = try? await URLSession.shared.data(from: response) }
        })
        #expect(try await service.authorizeLibraryScopes(["user-library-read"]).accessToken == "LIBRARY")
    }

    @Test func occupiedLibraryCallbackPortDoesNotOpenBrowser() async throws {
        let occupied = LoopbackCallbackListener(expectedState: "unused")
        let port = try await occupied.start()
        let service = SpotifyAuthService(clientID: "dashboard", client: makeClient(), store: InMemoryTokenStore(),
                                         callbackPort: UInt16(port), callbackPath: "/callback",
                                         openURL: { _ in Issue.record("An unbound callback must not open OAuth") })
        await #expect(throws: CallbackError.listenerFailed) {
            _ = try await service.authorizeLibraryScopes(["user-library-read"])
        }
        await occupied.stop()
    }

    @Test func signOutReleasesAbandonedFixedCallbackForNextConsent() async throws {
        AuthFlowStubProtocol.handler = { _ in (200, Data(self.librarySuccess.utf8)) }
        let reserved = LoopbackCallbackListener(expectedState: "unused")
        let port = try await reserved.start()
        await reserved.stop()
        let opened = AsyncStream<URL>.makeStream()
        let firstService = SpotifyAuthService(clientID: "dashboard", client: makeClient(), store: InMemoryTokenStore(),
                                              callbackPort: UInt16(port), callbackPath: "/callback",
                                              openURL: { _ = opened.continuation.yield($0) })
        let abandoned = Task { try await firstService.authorizeLibraryScopes(["user-library-read"]) }
        var iterator = opened.stream.makeAsyncIterator()
        let firstURL = try #require(await iterator.next())
        await firstService.signOut()

        let nextService = SpotifyAuthService(clientID: "dashboard", client: makeClient(), store: InMemoryTokenStore(),
                                             callbackPort: UInt16(port), callbackPath: "/callback", openURL: { url in
            let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
            let callback = URL(string: "\(query["redirect_uri"]!)?code=TESTCODE&state=\(query["state"]!)")!
            Task { _ = try? await URLSession.shared.data(from: callback) }
        })
        var nextToken: TokenSet?
        do { nextToken = try await nextService.authorizeLibraryScopes(["user-library-read"]) }
        catch { Issue.record("A new consent could not bind the port after sign-out: \(error)") }

        let firstQuery = Dictionary(uniqueKeysWithValues: URLComponents(url: firstURL, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        let firstCallback = URL(string: "\(firstQuery["redirect_uri"]!)?code=TESTCODE&state=\(firstQuery["state"]!)")!
        _ = try? await URLSession.shared.data(from: firstCallback)
        _ = try? await abandoned.value
        #expect(nextToken?.accessToken == "LIBRARY")
    }

    @Test func libraryConsentWidensExistingGrant() async throws {
        let widened = #"{"access_token":"WIDE","token_type":"Bearer","expires_in":3600,"refresh_token":"RT","scope":"user-library-read user-library-modify"}"#
        AuthFlowStubProtocol.handler = { _ in (200, Data(widened.utf8)) }
        let store = InMemoryTokenStore()
        try store.save(TokenSet(accessToken: "OLD", refreshToken: "RT", expiresAt: Date().addingTimeInterval(3600), grantedScopes: ["user-library-read"]))
        let service = SpotifyAuthService(clientID: "dashboard", client: makeClient(), store: store, openURL: { url in
            let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
            #expect(Set(query["scope"]!.split(separator: " ").map(String.init)) == ["user-library-read", "user-library-modify"])
            let callback = URL(string: "\(query["redirect_uri"]!)?code=TESTCODE&state=\(query["state"]!)")!
            Task { _ = try? await URLSession.shared.data(from: callback) }
        })
        let token = try await service.authorizeLibraryScopes(["user-library-modify"])
        #expect(token.grantedScopes == ["user-library-read", "user-library-modify"])
    }

    @Test func libraryConsentNeverCarriesPlaybackScopeFromStoredGrant() async throws {
        let widened = #"{"access_token":"WIDE","token_type":"Bearer","expires_in":3600,"scope":"user-library-read user-library-modify"}"#
        AuthFlowStubProtocol.handler = { _ in (200, Data(widened.utf8)) }
        let store = InMemoryTokenStore()
        try store.save(TokenSet(accessToken: "OLD", refreshToken: "RT", expiresAt: Date().addingTimeInterval(3600), grantedScopes: ["streaming", "user-library-read"]))
        let service = SpotifyAuthService(clientID: "dashboard", client: makeClient(), store: store, openURL: { url in
            let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
            #expect(Set(query["scope"]!.split(separator: " ").map(String.init)) == ["user-library-read", "user-library-modify"])
            let callback = URL(string: "\(query["redirect_uri"]!)?code=TESTCODE&state=\(query["state"]!)")!
            Task { _ = try? await URLSession.shared.data(from: callback) }
        })
        _ = try await service.authorizeLibraryScopes(["user-library-modify"])
    }

    @Test func libraryConsentRejectsMissingScopes() async throws {
        AuthFlowStubProtocol.handler = { _ in (200, Data(self.librarySuccess.utf8)) }
        let store = InMemoryTokenStore()
        let old = TokenSet(accessToken: "OLD", refreshToken: "RT", expiresAt: Date().addingTimeInterval(3600), grantedScopes: ["user-library-read"])
        try store.save(old)
        let service = SpotifyAuthService(clientID: "dashboard", client: makeClient(), store: store, openURL: { url in
            let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
            let callback = URL(string: "\(query["redirect_uri"]!)?code=TESTCODE&state=\(query["state"]!)")!
            Task { _ = try? await URLSession.shared.data(from: callback) }
        })
        await #expect(throws: LibraryError.authorizationRequired) {
            _ = try await service.authorizeLibraryScopes(["user-library-modify"])
        }
        #expect(store.load() == old)
    }

    @Test func libraryGrantRestoresLazilyWithoutBrowser() async throws {
        let store = InMemoryTokenStore()
        try store.save(TokenSet(accessToken: "LIBRARY_SAVED", refreshToken: "RT",
                                expiresAt: Date().addingTimeInterval(3600), grantedScopes: ["user-library-read"]))
        let relaunched = SpotifyAuthService(clientID: "dashboard", client: makeClient(), store: store,
                                            openURL: { _ in Issue.record("Restoring a grant must not open OAuth") })
        #expect(try await relaunched.validAccessToken(requiredScopes: ["user-library-read"]) == "LIBRARY_SAVED")
    }

    @Test func libraryConsentCancelledBySignOut() async throws {
        AuthFlowStubProtocol.handler = { _ in (200, Data(self.librarySuccess.utf8)) }
        let store = InMemoryTokenStore()
        let box = LateBinding<SpotifyAuthService>()
        let service = SpotifyAuthService(clientID: "dashboard", client: makeClient(), store: store, openURL: { url in
            let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
            Task {
                await box.value?.signOut()
                let callback = URL(string: "\(query["redirect_uri"]!)?code=TESTCODE&state=\(query["state"]!)")!
                _ = try? await URLSession.shared.data(from: callback)
            }
        })
        box.value = service
        await #expect(throws: PlayerError.authDenied) {
            _ = try await service.authorizeLibraryScopes(["user-library-read"])
        }
        #expect(store.load() == nil)
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
                #expect(URL(string: redirectURI)?.path == "/login")
                let callbackURL = URL(string: "\(redirectURI)?code=TESTCODE&state=\(state)")!
                Task { _ = try? await URLSession.shared.data(from: callbackURL) }
            }
        )

        let tokens = try await service.signIn()

        #expect(tokens.accessToken == "AT")
        #expect(tokens.grantedScopes == ["streaming"])
        #expect(store.load()?.accessToken == "AT")
    }

    /// Actors are reentrant across `await`: `signOut()` can run to completion
    /// while `signIn()` is suspended waiting for the browser callback. The
    /// opener awaits `signOut()` before firing that callback, so `signOut()`
    /// is always fully finished before `signIn()` resumes -- deterministic,
    /// not a race that happens to pass.
    @Test func signOutWhileSignInIsSuspendedDiscardsTheStaleResultInsteadOfResurrectingTheSession() async throws {
        AuthFlowStubProtocol.handler = { _ in (200, Data(self.success.utf8)) }
        let store = InMemoryTokenStore()
        let serviceBox = LateBinding<SpotifyAuthService>()
        let service = SpotifyAuthService(
            clientID: "client123",
            client: makeClient(),
            store: store,
            openURL: { url in
                let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
                guard let redirectURI = query["redirect_uri"], let state = query["state"] else { return }
                Task {
                    await serviceBox.value?.signOut()
                    let callbackURL = URL(string: "\(redirectURI)?code=TESTCODE&state=\(state)")!
                    _ = try? await URLSession.shared.data(from: callbackURL)
                }
            }
        )
        serviceBox.value = service

        await #expect(throws: PlayerError.authDenied) {
            _ = try await service.signIn()
        }
        #expect(store.load() == nil)
    }
    @Test func missingScopesNeverOpenBrowserOrRefresh() async throws {
        let store = InMemoryTokenStore()
        try store.save(TokenSet(accessToken: "OLD_FAKE", refreshToken: "RT", expiresAt: .distantPast, grantedScopes: ["streaming"]))
        AuthFlowStubProtocol.handler = { _ in Issue.record("Unexpected refresh"); return (500, Data()) }
        let service = SpotifyAuthService(clientID: "client123", client: makeClient(), store: store, openURL: { _ in Issue.record("Unexpected browser") })
        await #expect(throws: LibraryError.authorizationRequired) {
            _ = try await service.validAccessToken(requiredScopes: ["user-library-read"])
        }
    }

    @Test func overlappingConsumersShareRefresh() async throws {
        let gate = RefreshGate()
        ControlledRefreshProtocol.gate = gate
        let store = InMemoryTokenStore()
        try store.save(TokenSet(accessToken: "OLD", refreshToken: "RT", expiresAt: .distantPast, grantedScopes: ["streaming", "user-library-read"]))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ControlledRefreshProtocol.self]
        let service = SpotifyAuthService(clientID: "test", client: TokenClient(clientID: "test", session: URLSession(configuration: config)), store: store)
        let results = Task {
            try await withThrowingTaskGroup(of: String.self) { group in
                for _ in 0..<20 { group.addTask { try await service.validAccessToken(requiredScopes: ["user-library-read"]) } }
                var values: [String] = []
                for try await value in group { values.append(value) }
                return values
            }
        }
        for await _ in gate.started.stream { break }
        // The response is explicitly held while the consumers enter the actor.
        for _ in 0..<100 { await Task.yield() }
        gate.release()
        #expect(try await results.value == Array(repeating: "NEW_FAKE", count: 20))
        #expect(gate.requestCount == 1)
        #expect(store.load()?.grantedScopes == ["streaming", "user-library-read"])
    }

    @Test func signOutDuringRefreshCannotRestoreCredentials() async throws {
        let gate = RefreshGate()
        ControlledRefreshProtocol.gate = gate
        let store = InMemoryTokenStore()
        try store.save(TokenSet(accessToken: "OLD", refreshToken: "RT", expiresAt: .distantPast, grantedScopes: ["streaming"]))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ControlledRefreshProtocol.self]
        let service = SpotifyAuthService(clientID: "test", client: TokenClient(clientID: "test", session: URLSession(configuration: config)), store: store)
        let request = Task { try await service.validAccessToken() }
        for await _ in gate.started.stream { break }
        await service.signOut()
        gate.release()
        do { _ = try await request.value; Issue.record("Stale refresh returned a token") } catch {}
        #expect(store.load() == nil)
    }


    @Test func listeningHistoryConsentWidensTheLibraryGrant() async throws {
        let widened = #"{"access_token":"WIDE","token_type":"Bearer","expires_in":3600,"refresh_token":"RT","scope":"user-library-read user-read-recently-played user-top-read"}"#
        AuthFlowStubProtocol.handler = { _ in (200, Data(widened.utf8)) }
        let store = InMemoryTokenStore()
        try store.save(TokenSet(accessToken: "OLD", refreshToken: "RT", expiresAt: Date().addingTimeInterval(3600), grantedScopes: ["user-library-read"]))
        let service = SpotifyAuthService(clientID: "dashboard", client: makeClient(), store: store, openURL: { url in
            let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
            #expect(Set(query["scope"]!.split(separator: " ").map(String.init)) == ["user-library-read", "user-read-recently-played", "user-top-read"])
            let callback = URL(string: "\(query["redirect_uri"]!)?code=TESTCODE&state=\(query["state"]!)")!
            Task { _ = try? await URLSession.shared.data(from: callback) }
        })
        let token = try await service.authorizeLibraryScopes(["user-read-recently-played", "user-top-read"])
        #expect(token.grantedScopes == ["user-library-read", "user-read-recently-played", "user-top-read"])
    }
}

private final class RefreshGate: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [ControlledRefreshProtocol] = []
    private var released = false
    private var count = 0
    let started = AsyncStream<Void>.makeStream()
    var requestCount: Int { lock.withLock { count } }
    func receive(_ request: ControlledRefreshProtocol) {
        let respond = lock.withLock {
            count += 1
            if released { return true }
            pending.append(request)
            return false
        }
        started.continuation.yield(())
        if respond { request.respond() }
    }
    func release() {
        let requests = lock.withLock {
            released = true
            let result = pending
            pending = []
            return result
        }
        for request in requests { request.respond() }
    }
}

private final class ControlledRefreshProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var gate = RefreshGate()
    private let lock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.gate.receive(self) }
    override func stopLoading() { lock.withLock { stopped = true } }
    func respond() {
        lock.withLock {
            guard !stopped else { return }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"access_token":"NEW_FAKE","expires_in":3600}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}
