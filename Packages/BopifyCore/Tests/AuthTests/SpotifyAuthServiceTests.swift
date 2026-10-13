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

    @Test func cancellingPendingAuthorizationPreservesSavedCredentials() async throws {
        let store = InMemoryTokenStore()
        let saved = TokenSet(accessToken: "SAVED_FAKE", refreshToken: "RT", expiresAt: .distantFuture, grantedScopes: ["streaming"])
        try store.save(saved)
        let opened = AsyncStream<URL>.makeStream()
        let service = SpotifyAuthService(clientID: "test", client: makeClient(), store: store, openURL: { opened.continuation.yield($0) })
        let signIn = Task { try await service.signIn() }
        var iterator = opened.stream.makeAsyncIterator()
        _ = await iterator.next()
        await service.cancelPendingWork()
        await #expect(throws: PlayerError.authDenied) { _ = try await signIn.value }
        #expect(store.load() == saved)
        #expect(try await service.validAccessToken() == "SAVED_FAKE")
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
        try await firstService.signOut()

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
                try? await box.value?.signOut()
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
                    try? await serviceBox.value?.signOut()
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

    @Test func rejectedUnexpiredTokenRefreshes() async throws {
        AuthFlowStubProtocol.handler = { _ in (200, Data(#"{"access_token":"NEW_FAKE","expires_in":3600}"#.utf8)) }
        let store = InMemoryTokenStore()
        try store.save(TokenSet(accessToken: "OLD_FAKE", refreshToken: "RT", expiresAt: .distantFuture, grantedScopes: ["streaming"]))
        let service = SpotifyAuthService(clientID: "test", client: makeClient(), store: store)
        #expect(try await service.validAccessToken(rejecting: "OLD_FAKE") == "NEW_FAKE")
        #expect(store.load()?.refreshToken == "RT")
    }

    @Test func rejectedOldTokenUsesNewerCredential() async throws {
        AuthFlowStubProtocol.handler = { _ in Issue.record("Unexpected refresh"); return (500, Data()) }
        let store = InMemoryTokenStore()
        try store.save(TokenSet(accessToken: "NEW_FAKE", refreshToken: "RT", expiresAt: .distantFuture, grantedScopes: ["streaming"]))
        let service = SpotifyAuthService(clientID: "test", client: makeClient(), store: store)
        #expect(try await service.validAccessToken(rejecting: "OLD_FAKE") == "NEW_FAKE")
    }

    @Test func forcedAndOrdinaryRefreshShareRequest() async throws {
        let gate = RefreshGate()
        ControlledRefreshProtocol.gate = gate
        let store = InMemoryTokenStore()
        try store.save(TokenSet(accessToken: "OLD", refreshToken: "RT", expiresAt: .distantPast, grantedScopes: ["streaming"]))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ControlledRefreshProtocol.self]
        let service = SpotifyAuthService(clientID: "test", client: TokenClient(clientID: "test", session: URLSession(configuration: config)), store: store)
        let first = Task { try await service.validAccessToken() }
        for await _ in gate.started.stream { break }
        let second = Task { try await service.validAccessToken(rejecting: "OLD") }
        for _ in 0..<100 { await Task.yield() }
        gate.release()
        #expect(try await first.value == "NEW_FAKE")
        #expect(try await second.value == "NEW_FAKE")
        #expect(gate.requestCount == 1)
    }

    @Test func signOutDuringForcedRefreshCannotSave() async throws {
        let gate = RefreshGate()
        ControlledRefreshProtocol.gate = gate
        let store = InMemoryTokenStore()
        try store.save(TokenSet(accessToken: "OLD", refreshToken: "RT", expiresAt: .distantFuture, grantedScopes: ["streaming"]))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ControlledRefreshProtocol.self]
        let service = SpotifyAuthService(clientID: "test", client: TokenClient(clientID: "test", session: URLSession(configuration: config)), store: store)
        let request = Task { try await service.validAccessToken(rejecting: "OLD") }
        for await _ in gate.started.stream { break }
        try await service.signOut()
        gate.release()
        do { _ = try await request.value; Issue.record("Stale forced refresh returned") } catch {}
        #expect(store.load() == nil)
    }

    @Test func newConsentInvalidatesForcedRefresh() async throws {
        let gate = RefreshGate()
        ControlledRefreshProtocol.gate = gate
        let store = InMemoryTokenStore()
        try store.save(TokenSet(accessToken: "OLD", refreshToken: "RT", expiresAt: .distantFuture, grantedScopes: ["streaming"]))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ControlledRefreshProtocol.self]
        let binding = LateBinding<SpotifyAuthService>()
        let service = SpotifyAuthService(clientID: "test", client: TokenClient(clientID: "test", session: URLSession(configuration: config)), store: store, openURL: { _ in Task { try? await binding.value?.signOut() } })
        binding.value = service
        let request = Task { try await service.validAccessToken(rejecting: "OLD") }
        for await _ in gate.started.stream { break }
        do { _ = try await service.signIn(); Issue.record("Expected cancelled consent") } catch {}
        gate.release()
        do { _ = try await request.value; Issue.record("Old refresh survived consent") } catch {}
        #expect(store.load() == nil)
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
        try await service.signOut()
        gate.release()
        do { _ = try await request.value; Issue.record("Stale refresh returned a token") } catch {}
        #expect(store.load() == nil)
    }


    @Test(arguments: [KeychainError.unavailable(-25308), .accessDenied(-25293), .corrupt, .unexpected(-9999)])
    func failedRestorationPreservesCredentialsAndDoesNotOpenConsent(_ error: KeychainError) async throws {
        let store = FaultTokenStore()
        store.readError = error
        AuthFlowStubProtocol.handler = { _ in Issue.record("Unexpected token request"); return (500, Data()) }
        let service = SpotifyAuthService(clientID: "test", client: makeClient(), store: store, openURL: { _ in Issue.record("Unexpected consent") })
        let expected: PlayerError
        switch error {
        case .accessDenied: expected = .credentialAccessDenied
        case .corrupt: expected = .credentialCorrupt
        default: expected = .credentialUnavailable
        }
        await #expect(throws: expected) { try await service.restore() }
        await #expect(throws: expected) { try await service.validAccessToken() }
        if error != .corrupt {
            await #expect(throws: expected) { try await service.authorizeLibraryScopes(["user-library-read"]) }
        }
        #expect(store.saveCount == 0 && store.clearCount == 0)
        store.readError = nil
        #expect(try await service.restore() == store.saved)
        #expect(try await service.validAccessToken() == "OLD")
        store.readError = error
        await #expect(throws: expected) { try await service.restore() }
        #expect(try await service.validAccessToken() == "OLD")
    }

    @Test func consentSaveFailurePreservesThePreviousGrant() async throws {
        let store = FaultTokenStore()
        store.failSave = true
        AuthFlowStubProtocol.handler = { _ in (200, Data(self.success.utf8)) }
        let service = SpotifyAuthService(clientID: "test", client: makeClient(), store: store, openURL: { url in
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            let redirect = query.first { $0.name == "redirect_uri" }!.value!
            let state = query.first { $0.name == "state" }!.value!
            Task { _ = try? await URLSession.shared.data(from: URL(string: "\(redirect)?code=TEST&state=\(state)")!) }
        })
        _ = try await service.restore()
        await #expect(throws: PlayerError.credentialSaveFailed) { try await service.signIn() }
        #expect(store.saved?.accessToken == "OLD" && store.clearCount == 0)
        #expect(try await service.validAccessToken() == "OLD")
    }

    @Test func failedRefreshSaveCanRetryPersistenceWithoutRefreshingAgain() async throws {
        let store = FaultTokenStore(expired: true)
        store.failSave = true
        AuthFlowStubProtocol.handler = { _ in (200, Data(#"{"access_token":"NEW","refresh_token":"ROTATED","expires_in":3600}"#.utf8)) }
        let service = SpotifyAuthService(clientID: "test", client: makeClient(), store: store)
        await #expect(throws: PlayerError.credentialSaveFailed) { try await service.validAccessToken() }
        #expect(store.saved?.accessToken == "OLD")
        store.failSave = false
        AuthFlowStubProtocol.handler = { _ in Issue.record("Repeated refresh after token rotation"); return (500, Data()) }
        #expect(try await service.validAccessToken() == "NEW")
        #expect(store.saved?.refreshToken == "ROTATED" && store.saveCount == 2)
    }

    @Test func expiredPendingRefreshIsSavedThenRenewedUsingTheRotatedGrant() async throws {
        let store = FaultTokenStore(expired: true)
        store.failSave = true
        AuthFlowStubProtocol.handler = { _ in (200, Data(#"{"access_token":"EXPIRED","refresh_token":"ROTATED","expires_in":-1}"#.utf8)) }
        let service = SpotifyAuthService(clientID: "test", client: makeClient(), store: store)
        await #expect(throws: PlayerError.credentialSaveFailed) { try await service.validAccessToken() }
        store.failSave = false
        AuthFlowStubProtocol.handler = { request in
            var body = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    body.append(contentsOf: buffer[..<count])
                }
            }
            #expect(String(data: body, encoding: .utf8)?.contains("refresh_token=ROTATED") == true)
            return (200, Data(#"{"access_token":"FRESH","expires_in":3600}"#.utf8))
        }
        #expect(try await service.validAccessToken() == "FRESH")
        #expect(store.saved?.accessToken == "FRESH" && store.saved?.refreshToken == "ROTATED")
        #expect(store.saveCount == 3)
    }

    @Test func signOutDiscardsAnUnsavedRotatedGrant() async throws {
        let store = FaultTokenStore(expired: true)
        store.failSave = true
        AuthFlowStubProtocol.handler = { _ in (200, Data(#"{"access_token":"UNSAVED","refresh_token":"ROTATED","expires_in":3600}"#.utf8)) }
        let service = SpotifyAuthService(clientID: "test", client: makeClient(), store: store)
        await #expect(throws: PlayerError.credentialSaveFailed) { try await service.validAccessToken() }
        try await service.signOut()
        store.failSave = false
        await #expect(throws: PlayerError.authExpired) { try await service.validAccessToken() }
        #expect(store.saved == nil && store.saveCount == 1 && store.clearCount == 1)
    }

    @Test func newConsentDiscardsAnUnsavedRotatedGrant() async throws {
        let store = FaultTokenStore(expired: true)
        store.failSave = true
        AuthFlowStubProtocol.handler = { _ in (200, Data(#"{"access_token":"UNSAVED","refresh_token":"ROTATED","expires_in":3600}"#.utf8)) }
        let service = SpotifyAuthService(clientID: "test", client: makeClient(), store: store, openURL: { url in
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            let redirect = query.first { $0.name == "redirect_uri" }!.value!
            let state = query.first { $0.name == "state" }!.value!
            Task { _ = try? await URLSession.shared.data(from: URL(string: "\(redirect)?code=TEST&state=\(state)")!) }
        })
        await #expect(throws: PlayerError.credentialSaveFailed) { try await service.validAccessToken() }
        store.failSave = false
        AuthFlowStubProtocol.handler = { _ in (200, Data(self.success.utf8)) }
        #expect(try await service.signIn().accessToken == "AT")
        #expect(try await service.validAccessToken() == "AT")
        #expect(store.saved?.refreshToken == "RT" && store.saveCount == 2)
    }

    @Test func allRefreshWaitersFailWhenPersistenceFails() async throws {
        let gate = RefreshGate()
        ControlledRefreshProtocol.gate = gate
        let store = FailingSaveTokenStore()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ControlledRefreshProtocol.self]
        let service = SpotifyAuthService(clientID: "test", client: TokenClient(clientID: "test", session: URLSession(configuration: config)), store: store)
        let first = Task { try await service.validAccessToken() }
        for await _ in gate.started.stream { break }
        let second = Task { try await service.validAccessToken(rejecting: "OLD") }
        for _ in 0..<100 { await Task.yield() }
        gate.release()
        for request in [first, second] {
            await #expect(throws: PlayerError.credentialSaveFailed) { try await request.value }
        }
        #expect(store.load()?.accessToken == "OLD")
        #expect(store.saveCount == 1)
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

private final class FailingSaveTokenStore: TokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var saveCount: Int { lock.withLock { count } }
    func load() -> TokenSet? {
        TokenSet(accessToken: "OLD", refreshToken: "RT", expiresAt: .distantPast, grantedScopes: ["streaming"])
    }
    func save(_ tokens: TokenSet) throws {
        lock.withLock { count += 1 }
        throw KeychainError.unexpected(-25308)
    }
    func clear() throws { Issue.record("Unexpected credential deletion") }
}

private final class FaultTokenStore: TokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: TokenSet?
    private var readFault: KeychainError?
    private var saveFault = false
    private var saves = 0, clears = 0
    init(expired: Bool = false) {
        tokens = TokenSet(accessToken: "OLD", refreshToken: "RT", expiresAt: expired ? .distantPast : .distantFuture, grantedScopes: ["streaming"])
    }
    var saved: TokenSet? { lock.withLock { tokens } }
    var saveCount: Int { lock.withLock { saves } }
    var clearCount: Int { lock.withLock { clears } }
    var readError: KeychainError? {
        get { lock.withLock { readFault } }
        set { lock.withLock { readFault = newValue } }
    }
    var failSave: Bool {
        get { lock.withLock { saveFault } }
        set { lock.withLock { saveFault = newValue } }
    }
    func load() throws -> TokenSet? {
        try lock.withLock { if let readFault { throw readFault }; return tokens }
    }
    func save(_ tokens: TokenSet) throws {
        try lock.withLock {
            saves += 1
            if saveFault { throw KeychainError.unavailable(-25308) }
            self.tokens = tokens
        }
    }
    func clear() throws { lock.withLock { clears += 1; tokens = nil } }
}
