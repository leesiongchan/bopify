import Testing
import Foundation
@testable import BopifyAuth
import BopifyDomain

@Suite("LibraryAuthorization", .serialized)
struct LibraryAuthorizationTests {
    private let id = "25bbd3bacca4412b80f17b892072af71"
    private let other = "0123456789abcdef0123456789abcdef"

    /// Runs `body` against a throwaway suite named by a temp path: `removePersistentDomain` alone still
    /// leaves an empty plist in ~/Library/Preferences.
    private func withSuite(_ body: (String, UserDefaults) async throws -> Void) async rethrows {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryAuthorizationTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = directory.appendingPathComponent("defaults").path
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        try await body(suite, defaults)
    }

    private func grant() -> TokenSet {
        TokenSet(accessToken: "LIBRARY", refreshToken: "LIBRARY_RT",
                 expiresAt: Date().addingTimeInterval(3600), grantedScopes: ["user-library-read"])
    }

    private func authorization(_ suite: String, store: InMemoryTokenStore) -> LibraryAuthorization {
        LibraryAuthorization(suiteName: suite) { clientID in
            SpotifyAuthService(clientID: clientID, store: store, openURL: { _ in })
        }
    }

    @Test func normalizesPastedInput() {
        #expect(LibraryAuthorization.normalized("  25BBD3BACCA4412B80F17B892072AF71\n") == id)
    }

    @Test(arguments: ["", "25bbd3bacca4412b80f17b892072af7", "25bbd3bacca4412b80f17b892072af711",
                      "g5bbd3bacca4412b80f17b892072af71", "２5bbd3bacca4412b80f17b892072af71"])
    func rejectsMalformedIDs(_ raw: String) {
        #expect(LibraryAuthorization.normalized(raw) == nil)
    }

    @Test func ignoresAnInvalidStoredID() async {
        await withSuite { _, defaults in
            defaults.set("not-an-id", forKey: LibraryAuthorization.defaultsKey)
            #expect(LibraryAuthorization.storedClientID(in: defaults) == nil)
        }
    }

    @Test func missingIDRequiresAuthorization() async {
        await withSuite { suite, _ in
            let library = authorization(suite, store: InMemoryTokenStore())
            await #expect(throws: LibraryError.authorizationRequired) {
                try await library.validAccessToken(requiredScopes: ["user-library-read"])
            }
            await #expect(throws: LibraryError.authorizationRequired) {
                try await library.authorize(["user-library-read"])
            }
        }
    }

    @Test func storedIDServesItsGrant() async throws {
        try await withSuite { suite, defaults in
            defaults.set(id, forKey: LibraryAuthorization.defaultsKey)
            let store = InMemoryTokenStore()
            try store.save(grant())
            let library = authorization(suite, store: store)
            #expect(try await library.validAccessToken(requiredScopes: ["user-library-read"]) == "LIBRARY")
        }
    }

    @Test func settingAnIDPersistsItAndClearsAnyEarlierGrant() async throws {
        try await withSuite { suite, defaults in
            let store = InMemoryTokenStore()
            try store.save(grant())  // left behind by a client the app no longer knows
            let library = authorization(suite, store: store)
            #expect(try await library.setClientID(id.uppercased()) == id)
            #expect(defaults.string(forKey: LibraryAuthorization.defaultsKey) == id)
            #expect(store.load() == nil)
        }
    }

    @Test func replacingTheIDClearsTheGrant() async throws {
        try await withSuite { suite, defaults in
            defaults.set(id, forKey: LibraryAuthorization.defaultsKey)
            let store = InMemoryTokenStore()
            try store.save(grant())
            let library = authorization(suite, store: store)
            _ = try await library.setClientID(other)
            #expect(store.load() == nil)
            await #expect(throws: LibraryError.authorizationRequired) {
                try await library.validAccessToken(requiredScopes: ["user-library-read"])
            }
        }
    }

    /// `cancelPendingWork()` alone would leave the old service holding its in-memory grant.
    @Test func replacingTheIDSignsOutTheOldClient() async throws {
        try await withSuite { suite, defaults in
            defaults.set(id, forKey: LibraryAuthorization.defaultsKey)
            let store = InMemoryTokenStore()
            try store.save(grant())
            let created = CreatedServices()
            let library = LibraryAuthorization(suiteName: suite) { clientID in
                created.record(SpotifyAuthService(clientID: clientID, store: store, openURL: { _ in }))
            }
            let old = try #require(created.first)
            #expect(try await old.validAccessToken(requiredScopes: ["user-library-read"]) == "LIBRARY")
            _ = try await library.setClientID(other)
            await #expect(throws: LibraryError.authorizationRequired) {
                try await old.validAccessToken(requiredScopes: ["user-library-read"])
            }
        }
    }

    @Test(arguments: [KeychainError.unavailable(-25308), .accessDenied(-25293), .corrupt, .unexpected(-1)])
    func temporaryCredentialReadFailuresPreserveTheLibraryIDAndGrant(_ failure: KeychainError) async throws {
        try await withSuite { suite, defaults in
            defaults.set(id, forKey: LibraryAuthorization.defaultsKey)
            let store = LibraryReadFaultStore(tokens: grant(), failure: failure)
            let library = LibraryAuthorization(suiteName: suite) { clientID in
                SpotifyAuthService(clientID: clientID, store: store, openURL: { _ in store.recordBrowser() })
            }
            let expected: PlayerError
            switch failure {
            case .accessDenied: expected = .credentialAccessDenied
            case .corrupt: expected = .credentialCorrupt
            default: expected = .credentialUnavailable
            }
            await #expect(throws: expected) {
                try await library.validAccessToken(requiredScopes: ["user-library-read"])
            }
            #expect(defaults.string(forKey: LibraryAuthorization.defaultsKey) == id)
            #expect(store.clears == 0 && store.browserOpens == 0)
            store.failure = nil
            let restored = try await library.validAccessToken(requiredScopes: ["user-library-read"])
            #expect(restored == "LIBRARY")
        }
    }

    @Test func replacingTheClientAbandonsConsentAndRejectsItsStaleCallback() async throws {
        try await withSuite { suite, defaults in
            defaults.set(id, forKey: LibraryAuthorization.defaultsKey)
            let reserved = LoopbackCallbackListener(expectedState: "unused")
            let port = try await reserved.start()
            await reserved.stop()
            let opened = AsyncStream<URL>.makeStream()
            defer { opened.continuation.finish() }
            let store = InMemoryTokenStore()
            let library = LibraryAuthorization(suiteName: suite) { clientID in
                let config = URLSessionConfiguration.ephemeral
                config.protocolClasses = [LibraryConsentStubProtocol.self]
                return SpotifyAuthService(clientID: clientID,
                    client: TokenClient(clientID: clientID, session: URLSession(configuration: config)),
                    store: store, callbackPort: UInt16(port), callbackPath: "/callback",
                    openURL: { opened.continuation.yield($0) })
            }
            let deadline = Task {
                try await Task.sleep(for: .seconds(10))
                opened.continuation.finish()
                await library.cancelPendingWork()
            }
            defer { deadline.cancel() }
            let oldConsent = Task { try await library.authorize(["user-library-read"]) }
            var iterator = opened.stream.makeAsyncIterator()
            let oldURL = try #require(await iterator.next())
            let oldQuery = Dictionary(uniqueKeysWithValues: URLComponents(url: oldURL, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
            #expect(oldQuery["client_id"] == id)
            _ = try await library.setClientID(other)
            await #expect(throws: PlayerError.authDenied) { try await oldConsent.value }
            let newConsent = Task { try await library.authorize(["user-library-read"]) }
            let newURL = try #require(await iterator.next())
            let newQuery = Dictionary(uniqueKeysWithValues: URLComponents(url: newURL, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
            #expect(newQuery["client_id"] == other)
            #expect(newQuery["redirect_uri"] == "http://127.0.0.1:\(port)/callback")
            let stale = URL(string: "\(newQuery["redirect_uri"]!)?code=STALE&state=\(oldQuery["state"]!)")!
            let (_, rejected) = try await URLSession.shared.data(from: stale)
            #expect((rejected as? HTTPURLResponse)?.statusCode == 400)
            #expect(store.load() == nil)
            let valid = URL(string: "\(newQuery["redirect_uri"]!)?code=NEW&state=\(newQuery["state"]!)")!
            _ = try await URLSession.shared.data(from: valid)
            try await newConsent.value
            #expect(try await library.validAccessToken(requiredScopes: ["user-library-read"]) == "NEW_LIBRARY")
            #expect(defaults.string(forKey: LibraryAuthorization.defaultsKey) == other)
        }
    }

    @Test(arguments: [true, false])
    func failedCredentialRemovalDoesNotPublishTheReplacementClient(_ hasStoredID: Bool) async throws {
        try await withSuite { suite, defaults in
            if hasStoredID { defaults.set(id, forKey: LibraryAuthorization.defaultsKey) }
            let store = LibraryReadFaultStore(tokens: grant(), failure: nil)
            store.failClear = true
            let library = LibraryAuthorization(suiteName: suite) { clientID in
                SpotifyAuthService(clientID: clientID, store: store, openURL: { _ in store.recordBrowser() })
            }
            await #expect(throws: PlayerError.credentialUnavailable) { try await library.setClientID(other) }
            #expect(defaults.string(forKey: LibraryAuthorization.defaultsKey) == (hasStoredID ? id : nil))
            if hasStoredID {
                let existing = try await library.validAccessToken(requiredScopes: ["user-library-read"])
                #expect(existing == "LIBRARY")
            } else {
                await #expect(throws: LibraryError.authorizationRequired) {
                    try await library.validAccessToken(requiredScopes: ["user-library-read"])
                }
            }
            #expect(store.browserOpens == 0)
            store.failClear = false
            let replacement = try await library.setClientID(other)
            #expect(replacement == other && defaults.string(forKey: LibraryAuthorization.defaultsKey) == other)
            #expect(try store.load() == nil)
        }
    }

    @Test func explicitLibraryConsentReplacesACorruptGrant() async throws {
        try await withSuite { suite, defaults in
            defaults.set(id, forKey: LibraryAuthorization.defaultsKey)
            let store = LibraryReadFaultStore(tokens: grant(), failure: .corrupt)
            let library = LibraryAuthorization(suiteName: suite) { clientID in
                let config = URLSessionConfiguration.ephemeral
                config.protocolClasses = [LibraryConsentStubProtocol.self]
                return SpotifyAuthService(clientID: clientID,
                    client: TokenClient(clientID: clientID, session: URLSession(configuration: config)), store: store,
                    callbackPath: "/callback", openURL: { url in
                        store.recordBrowser()
                        let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
                        let callback = URL(string: "\(query["redirect_uri"]!)?code=REPAIR&state=\(query["state"]!)")!
                        Task { _ = try? await URLSession.shared.data(from: callback) }
                    })
            }
            await #expect(throws: PlayerError.credentialCorrupt) {
                try await library.validAccessToken(requiredScopes: ["user-library-read"])
            }
            #expect(store.browserOpens == 0 && store.clears == 0)
            try await library.authorize(["user-library-read"])
            let repaired = try await library.validAccessToken(requiredScopes: ["user-library-read"])
            #expect(repaired == "NEW_LIBRARY" && store.browserOpens == 1 && store.clears == 0)
            let stored = try store.load()
            #expect(stored?.accessToken == "NEW_LIBRARY")
            let reopened = LibraryAuthorization(suiteName: suite) { clientID in
                SpotifyAuthService(clientID: clientID, store: store, openURL: { _ in store.recordBrowser() })
            }
            let restored = try await reopened.validAccessToken(requiredScopes: ["user-library-read"])
            #expect(restored == "NEW_LIBRARY" && store.browserOpens == 1)
            #expect(defaults.string(forKey: LibraryAuthorization.defaultsKey) == id)
        }
    }

    @Test func decliningCorruptGrantReplacementKeepsStoredCredentialsUntouched() async {
        await withSuite { suite, defaults in
            defaults.set(id, forKey: LibraryAuthorization.defaultsKey)
            let store = LibraryReadFaultStore(tokens: grant(), failure: .corrupt)
            let library = LibraryAuthorization(suiteName: suite) { clientID in
                let config = URLSessionConfiguration.ephemeral
                config.protocolClasses = [LibraryConsentStubProtocol.self]
                return SpotifyAuthService(clientID: clientID,
                    client: TokenClient(clientID: clientID, session: URLSession(configuration: config)), store: store,
                    callbackPath: "/callback", openURL: { url in
                        store.recordBrowser()
                        let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
                        let callback = URL(string: "\(query["redirect_uri"]!)?error=access_denied&state=\(query["state"]!)")!
                        Task { _ = try? await URLSession.shared.data(from: callback) }
                    })
            }
            await #expect(throws: PlayerError.authDenied) { try await library.authorize(["user-library-read"]) }
            #expect(throws: KeychainError.corrupt) { try store.load() }
            #expect(store.clears == 0 && store.browserOpens == 1)
            #expect(defaults.string(forKey: LibraryAuthorization.defaultsKey) == id)
        }
    }

    @Test func savingTheSameIDKeepsTheGrant() async throws {
        try await withSuite { suite, defaults in
            defaults.set(id, forKey: LibraryAuthorization.defaultsKey)
            let store = InMemoryTokenStore()
            try store.save(grant())
            let library = authorization(suite, store: store)
            _ = try await library.setClientID(" \(id.uppercased()) ")
            #expect(store.load() != nil)
        }
    }

    @Test func invalidIDLeavesStateUntouched() async throws {
        try await withSuite { suite, defaults in
            defaults.set(id, forKey: LibraryAuthorization.defaultsKey)
            let store = InMemoryTokenStore()
            try store.save(grant())
            let library = authorization(suite, store: store)
            await #expect(throws: LibraryClientIDError.invalid) { try await library.setClientID("nope") }
            #expect(defaults.string(forKey: LibraryAuthorization.defaultsKey) == id)
            #expect(store.load() != nil)
        }
    }
}

/// Records each auth service `makeAuth` builds, so a test can probe one after it is replaced.
private final class CreatedServices: @unchecked Sendable {
    private let lock = NSLock()
    private var services: [SpotifyAuthService] = []

    var first: SpotifyAuthService? { lock.withLock { services.first } }

    func record(_ service: SpotifyAuthService) -> SpotifyAuthService {
        lock.withLock { services.append(service) }
        return service
    }
}

private final class LibraryReadFaultStore: TokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: TokenSet?
    private var readFault: KeychainError?
    private var clearCount = 0, browserCount = 0
    private var clearFault = false
    init(tokens: TokenSet, failure: KeychainError?) { self.tokens = tokens; readFault = failure }
    var failure: KeychainError? {
        get { lock.withLock { readFault } }
        set { lock.withLock { readFault = newValue } }
    }
    var failClear: Bool {
        get { lock.withLock { clearFault } }
        set { lock.withLock { clearFault = newValue } }
    }
    var clears: Int { lock.withLock { clearCount } }
    var browserOpens: Int { lock.withLock { browserCount } }
    func recordBrowser() { lock.withLock { browserCount += 1 } }
    func load() throws -> TokenSet? {
        try lock.withLock { if let readFault { throw readFault }; return tokens }
    }
    func save(_ tokens: TokenSet) throws {
        lock.withLock {
            self.tokens = tokens
            if readFault == .corrupt { readFault = nil }
        }
    }
    func clear() throws {
        try lock.withLock {
            clearCount += 1
            if clearFault { throw KeychainError.unavailable(-25308) }
            tokens = nil
        }
    }
}

private final class LibraryConsentStubProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"access_token":"NEW_LIBRARY","refresh_token":"NEW_RT","expires_in":3600,"scope":"user-library-read"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
