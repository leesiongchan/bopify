import Foundation
import Testing
import BopifyAuth
import BopifyDomain

@Suite("Consent and refresh ownership", .serialized)
struct ConsentRefreshTests {
    @Test func aCancelledTaskNeverOpensConsentOrReplacesCredentials() async throws {
        let store = InMemoryTokenStore()
        let saved = TokenSet(accessToken: "SAVED", refreshToken: "RT", expiresAt: .distantFuture, grantedScopes: ["streaming"])
        try store.save(saved)
        let service = SpotifyAuthService(clientID: "test", store: store,
            openURL: { _ in Issue.record("Cancelled authorization opened the browser") })
        let request = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.signIn()
        }
        let cleanup = Task {
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            await service.cancelPendingWork()
        }
        defer { cleanup.cancel() }
        await #expect(throws: CancellationError.self) { _ = try await request.value }
        #expect(store.load() == saved)
    }

    @Test func cancellingBrowserConsentReleasesItsPortAndPreservesAnOldGrantRefresh() async throws {
        let gate = ConsentRefreshGate()
        ConsentRefreshProtocol.gate = gate
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConsentRefreshProtocol.self]
        let store = InMemoryTokenStore()
        try store.save(TokenSet(accessToken: "OLD", refreshToken: "OLD_RT", expiresAt: .distantPast,
                                grantedScopes: ["user-library-read"]))
        let opened = AsyncStream<URL>.makeStream()
        let service = SpotifyAuthService(clientID: "test",
            client: TokenClient(clientID: "test", session: URLSession(configuration: configuration)),
            store: store, openURL: { opened.continuation.yield($0) })
        let consent = Task { try await service.authorizeLibrary() }
        var urls = opened.stream.makeAsyncIterator()
        let url = try #require(await urls.next())
        let redirect = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "redirect_uri" })?.value.flatMap(URL.init(string:)))
        let refresh = Task { try await service.validAccessToken(requiredScopes: ["user-library-read"]) }
        var started = gate.started.stream.makeAsyncIterator()
        _ = await started.next()
        consent.cancel()
        let cleanup = Task {
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            await service.cancelPendingWork()
        }
        defer { cleanup.cancel() }
        await #expect(throws: CancellationError.self) { _ = try await consent.value }
        cleanup.cancel()
        let retry = LoopbackCallbackListener(expectedState: "retry")
        _ = try await retry.start(port: UInt16(try #require(redirect.port)))
        await retry.stop()
        gate.release()
        #expect(try await refresh.value == "OLD_REFRESHED")
        #expect(store.load()?.grantedScopes == ["user-library-read"])
    }

    @Test func cancellingTokenExchangePreservesCredentialsAndRejectsLateResponse() async throws {
        let gate = ConsentRefreshGate(holdExchange: true)
        ConsentRefreshProtocol.gate = gate
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConsentRefreshProtocol.self]
        let store = InMemoryTokenStore()
        let saved = TokenSet(accessToken: "SAVED", refreshToken: "RT", expiresAt: .distantFuture, grantedScopes: ["streaming"])
        try store.save(saved)
        let service = SpotifyAuthService(clientID: "test",
            client: TokenClient(clientID: "test", session: URLSession(configuration: configuration)),
            store: store, openURL: { url in
                let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!
                    .queryItems!.map { ($0.name, $0.value!) })
                Task { _ = try? await URLSession.shared.data(from: URL(string: query["redirect_uri"]! + "?code=NEW&state=" + query["state"]!)!) }
            })
        let consent = Task { try await service.signIn() }
        var started = gate.started.stream.makeAsyncIterator()
        _ = await started.next()
        consent.cancel()
        await #expect(throws: CancellationError.self) { _ = try await consent.value }
        gate.release()
        #expect(store.load() == saved)
        #expect(try await service.validAccessToken() == "SAVED")
    }

    @Test(arguments: [true, false])
    func newConsentKeepsItsGrantWhenAnOldGrantRefreshesDuringConsent(consentFinishesFirst: Bool) async throws {
        let gate = ConsentRefreshGate()
        ConsentRefreshProtocol.gate = gate
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConsentRefreshProtocol.self]
        let store = InMemoryTokenStore()
        try store.save(TokenSet(accessToken: "OLD", refreshToken: "OLD_RT", expiresAt: .distantPast,
                                grantedScopes: ["user-library-read"]))
        let opened = AsyncStream<URL>.makeStream()
        let service = SpotifyAuthService(clientID: "test",
            client: TokenClient(clientID: "test", session: URLSession(configuration: configuration)),
            store: store, openURL: { opened.continuation.yield($0) })
        let consent = Task { try await service.authorizeLibrary() }
        var urls = opened.stream.makeAsyncIterator()
        let url = try #require(await urls.next())
        let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!
            .queryItems!.map { ($0.name, $0.value!) })
        let refresh = Task { try await service.validAccessToken(requiredScopes: ["user-library-read"]) }
        var started = gate.started.stream.makeAsyncIterator()
        _ = await started.next()
        if !consentFinishesFirst {
            gate.release()
            #expect(try await refresh.value == "OLD_REFRESHED")
        }
        let callback = URL(string: query["redirect_uri"]! + "?code=NEW&state=" + query["state"]!)!
        _ = try await URLSession.shared.data(from: callback)
        #expect(try await consent.value.accessToken == "NEW_CONSENT")
        if consentFinishesFirst {
            gate.release()
            do { _ = try await refresh.value; Issue.record("A superseded refresh returned credentials") }
            catch {}
        }
        #expect(store.load()?.accessToken == "NEW_CONSENT")
        #expect(store.load()?.refreshToken == "NEW_RT")
        #expect(try await service.validAccessToken(requiredScopes: ["user-library-modify"]) == "NEW_CONSENT")
    }
}

private final class ConsentRefreshGate: @unchecked Sendable {
    private let lock = NSLock()
    private var held: ConsentRefreshProtocol?
    let started = AsyncStream<Void>.makeStream()
    let holdExchange: Bool

    init(holdExchange: Bool = false) { self.holdExchange = holdExchange }

    func hold(_ request: ConsentRefreshProtocol) {
        lock.withLock { held = request }
        started.continuation.yield(())
    }

    func release() {
        let request = lock.withLock { let request = held; held = nil; return request }
        request?.respond(#"{"access_token":"OLD_REFRESHED","expires_in":3600,"refresh_token":"OLD_RT"}"#)
    }
}

private final class ConsentRefreshProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var gate = ConsentRefreshGate()
    private let lock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { lock.withLock { stopped = true } }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        if Self.gate.holdExchange || String(decoding: body, as: UTF8.self).contains("grant_type=refresh_token") {
            Self.gate.hold(self)
        } else {
            respond(#"{"access_token":"NEW_CONSENT","expires_in":3600,"refresh_token":"NEW_RT","scope":"user-library-read user-library-modify user-read-recently-played user-top-read playlist-read-private playlist-read-collaborative user-follow-read"}"#)
        }
    }

    func respond(_ body: String) {
        lock.withLock {
            guard !stopped else { return }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}
