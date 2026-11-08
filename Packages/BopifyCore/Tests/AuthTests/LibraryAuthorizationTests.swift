import Testing
import Foundation
@testable import BopifyAuth
import BopifyDomain

@Suite("LibraryAuthorization", .serialized)
struct LibraryAuthorizationTests {
    private let id = "25bbd3bacca4412b80f17b892072af71"
    private let other = "0123456789abcdef0123456789abcdef"

    /// Users have registered this exact URI with their own Spotify apps; a change must be deliberate.
    @Test func redirectURIMatchesWhatUsersRegistered() {
        #expect(LibraryAuthorization.redirectURI == "http://127.0.0.1:8898/callback")
    }

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

    private func consentAuthorization(_ suite: String, store: any TokenStoring,
                                      openURL: @escaping @Sendable (URL) -> Void) -> LibraryAuthorization {
        LibraryAuthorization(suiteName: suite) { clientID in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [LibraryConsentStubProtocol.self]
            return SpotifyAuthService(clientID: clientID,
                client: TokenClient(clientID: clientID, session: URLSession(configuration: configuration)),
                store: store, callbackPath: "/callback", openURL: openURL)
        }
    }

    @Test func playbackAuthorizationKeepsAnExistingCompleteGrantQuiet() async throws {
        try await withSuite { suite, defaults in
            defaults.set(id, forKey: LibraryAuthorization.defaultsKey)
            let store = InMemoryTokenStore()
            let saved = TokenSet(accessToken: "FULL", refreshToken: "RT", expiresAt: .distantFuture,
                                 grantedScopes: LibraryAuthorization.requiredScopes.union(LibraryAuthorization.playbackScopes))
            try store.save(saved)
            let library = consentAuthorization(suite, store: store) { _ in Issue.record("Valid credentials must not open consent") }
            #expect(try await !library.authorizePlaybackIfNeeded())
            #expect(store.load() == saved)
        }
    }

    @Test(arguments: ["missing", "libraryOnly", "playbackOnly", "expired", "corrupt"])
    func explicitPlaybackAuthorizationRepairsOnlyMissingOrInvalidGrants(state: String) async throws {
        try await withSuite { suite, defaults in
            defaults.set(id, forKey: LibraryAuthorization.defaultsKey)
            let scopes = state == "libraryOnly" ? LibraryAuthorization.requiredScopes :
                state == "playbackOnly" ? LibraryAuthorization.playbackScopes :
                LibraryAuthorization.requiredScopes.union(LibraryAuthorization.playbackScopes)
            let saved = TokenSet(accessToken: "OLD", refreshToken: nil,
                                 expiresAt: state == "expired" ? .distantPast : .distantFuture, grantedScopes: scopes)
            let normal = InMemoryTokenStore()
            if state != "missing" { try normal.save(saved) }
            let store: any TokenStoring = state == "corrupt" ? LibraryReadFaultStore(tokens: saved, failure: .corrupt) : normal
            let opened = AuthOpenCounter()
            let library = consentAuthorization(suite, store: store) { url in
                opened.increment()
                let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
                let callback = URL(string: query["redirect_uri"]! + "?code=NEW&state=" + query["state"]!)!
                Task { _ = try? await URLSession.shared.data(from: callback) }
            }
            #expect(try await library.authorizePlaybackIfNeeded())
            #expect(opened.count == 1)
            #expect(try await library.validAccessToken(requiredScopes: scopes.union(LibraryAuthorization.playbackScopes)) == "NEW_LIBRARY")
        }
    }

    @Test(arguments: [KeychainError.unavailable(-25308), .accessDenied(-25293), .unexpected(-1)])
    func playbackAuthorizationPropagatesStorageFailuresWithoutConsent(failure: KeychainError) async throws {
        try await withSuite { suite, defaults in
            defaults.set(id, forKey: LibraryAuthorization.defaultsKey)
            let store = LibraryReadFaultStore(tokens: grant(), failure: failure)
            let library = consentAuthorization(suite, store: store) { _ in Issue.record("Storage failure must not open consent") }
            let expected: PlayerError = failure == .accessDenied(-25293) ? .credentialAccessDenied : .credentialUnavailable
            await #expect(throws: expected) { _ = try await library.authorizePlaybackIfNeeded() }
            #expect(store.clears == 0)
        }
    }

    @Test func playbackAuthorizationPropagatesRefreshNetworkFailureWithoutConsent() async throws {
        try await withSuite { suite, defaults in
            defaults.set(id, forKey: LibraryAuthorization.defaultsKey)
            let store = InMemoryTokenStore()
            let saved = TokenSet(accessToken: "OLD", refreshToken: "RT", expiresAt: .distantPast,
                                 grantedScopes: LibraryAuthorization.requiredScopes.union(LibraryAuthorization.playbackScopes))
            try store.save(saved)
            let library = LibraryAuthorization(suiteName: suite) { clientID in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [LibraryRefreshUnavailableProtocol.self]
                return SpotifyAuthService(clientID: clientID,
                    client: TokenClient(clientID: clientID, session: URLSession(configuration: configuration)),
                    store: store, openURL: { _ in Issue.record("Network failure must not open consent") })
            }
            await #expect(throws: PlayerError.networkUnavailable) { _ = try await library.authorizePlaybackIfNeeded() }
            #expect(store.load() == saved)
        }
    }

    @Test func cancelledPlaybackAuthorizationDoesNotOpenConsent() async throws {
        try await withSuite { suite, defaults in
            defaults.set(id, forKey: LibraryAuthorization.defaultsKey)
            let library = consentAuthorization(suite, store: InMemoryTokenStore()) { _ in Issue.record("Canceled work must not open consent") }
            let task = await MainActor.run {
                let task = Task { try await library.authorizePlaybackIfNeeded() }
                task.cancel()
                return task
            }
            await #expect(throws: CancellationError.self) { _ = try await task.value }
        }
    }

    @Test func playbackAuthorizationRejectsAnInProgressClientChange() async throws {
        try await withSuite { suite, defaults in
            defaults.set(id, forKey: LibraryAuthorization.defaultsKey)
            let store = BlockingClientChangeStore()
            let library = consentAuthorization(suite, store: store) { _ in Issue.record("An old selection must not authorize another client") }
            let replacement = Task { try await library.setClientID(other) }
            var clearing = store.started.stream.makeAsyncIterator()
            _ = await clearing.next()
            await #expect(throws: CancellationError.self) { _ = try await library.authorizePlaybackIfNeeded() }
            store.release.signal()
            let changedID = try await replacement.value
            #expect(changedID == other)
        }
    }

    @Test func replacingTheClientCancelsItsPendingPlaybackConsent() async throws {
        try await withSuite { suite, defaults in
            defaults.set(id, forKey: LibraryAuthorization.defaultsKey)
            let store = InMemoryTokenStore(), opened = AsyncStream<URL>.makeStream()
            let count = AuthOpenCounter()
            let library = consentAuthorization(suite, store: store) { url in
                count.increment()
                opened.continuation.yield(url)
            }
            let pending = Task { try await library.authorizePlaybackIfNeeded() }
            var urls = opened.stream.makeAsyncIterator()
            _ = await urls.next()
            let changedID = try await library.setClientID(other)
            #expect(changedID == other)
            do { _ = try await pending.value; Issue.record("The old client's playback request completed") }
            catch {}
            #expect(count.count == 1 && store.load() == nil)
            #expect(defaults.string(forKey: LibraryAuthorization.defaultsKey) == other)
        }
    }

    @Test func cancellingPendingPlaybackConsentReleasesOnlyItsCallbackAndPreservesGrant() async throws {
        try await withSuite { suite, defaults in
            defaults.set(id, forKey: LibraryAuthorization.defaultsKey)
            let store = InMemoryTokenStore()
            let saved = grant()
            try store.save(saved)
            let opened = AsyncStream<URL>.makeStream()
            let library = consentAuthorization(suite, store: store) { opened.continuation.yield($0) }
            let task = Task { try await library.authorizePlaybackIfNeeded() }
            var urls = opened.stream.makeAsyncIterator()
            let url = try #require(await urls.next())
            let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            let redirect = try #require(query.first { $0.name == "redirect_uri" }?.value.flatMap(URL.init(string:)))
            let start = ContinuousClock.now
            task.cancel()
            await #expect(throws: CancellationError.self) { _ = try await task.value }
            #expect(start.duration(to: .now) < .seconds(1))
            #expect(store.load() == saved)
            let replacement = LoopbackCallbackListener(expectedState: "replacement", expectedPath: "/callback")
            _ = try await replacement.start(port: UInt16(try #require(redirect.port)))
            await replacement.stop()
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
                try await library.authorize()
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
            let oldConsent = Task { try await library.authorize() }
            var iterator = opened.stream.makeAsyncIterator()
            let oldURL = try #require(await iterator.next())
            let oldQuery = Dictionary(uniqueKeysWithValues: URLComponents(url: oldURL, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
            #expect(oldQuery["client_id"] == id)
            _ = try await library.setClientID(other)
            await #expect(throws: PlayerError.authDenied) { try await oldConsent.value }
            let newConsent = Task { try await library.authorize() }
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
            try await library.authorize()
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
            await #expect(throws: PlayerError.authDenied) { try await library.authorize() }
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

    @Test(.timeLimit(.minutes(1))) func overlappingClientChangesCannotDeleteTheNewerConsent() async throws {
        try await withSuite { suite, defaults in
            defaults.set(id, forKey: LibraryAuthorization.defaultsKey)
            let store = BlockingClientChangeStore()
            let latest = "fedcba9876543210fedcba9876543210"
            let library = LibraryAuthorization(suiteName: suite) { clientID in
                let config = URLSessionConfiguration.ephemeral
                config.protocolClasses = [LibraryConsentStubProtocol.self]
                return SpotifyAuthService(clientID: clientID,
                    client: TokenClient(clientID: clientID, session: URLSession(configuration: config)),
                    store: store, callbackPath: "/callback", openURL: { url in
                        let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!
                            .queryItems!.map { ($0.name, $0.value!) })
                        let callback = URL(string: query["redirect_uri"]! + "?code=NEW&state=" + query["state"]!)!
                        Task { _ = try? await URLSession.shared.data(from: callback) }
                    })
            }
            let first = Task { try await library.setClientID(other) }
            var clearing = store.started.stream.makeAsyncIterator()
            _ = await clearing.next()
            // Serialized changes need the first clear released before they can finish.
            let deadline = Task {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                store.release.signal()
            }
            defer { deadline.cancel(); store.release.signal() }
            let second = Task {
                _ = try await library.setClientID(latest)
                try await library.authorize()
                store.release.signal()
            }
            _ = try await first.value
            try await second.value
            #expect(defaults.string(forKey: LibraryAuthorization.defaultsKey) == latest)
            #expect(store.load()?.accessToken == "NEW_LIBRARY")
            #expect(try await library.validAccessToken(requiredScopes: ["user-library-read"]) == "NEW_LIBRARY")
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

private final class BlockingClientChangeStore: TokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: TokenSet?
    private var blockNextClear = true
    let started = AsyncStream<Void>.makeStream()
    let release = DispatchSemaphore(value: 0)

    func load() -> TokenSet? { lock.withLock { tokens } }
    func save(_ tokens: TokenSet) { lock.withLock { self.tokens = tokens } }
    func clear() {
        let block = lock.withLock {
            let block = blockNextClear
            blockNextClear = false
            return block
        }
        if block {
            started.continuation.yield(())
            release.wait()
        }
        lock.withLock { tokens = nil }
    }
}

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
        client?.urlProtocol(self, didLoad: Data(#"{"access_token":"NEW_LIBRARY","refresh_token":"NEW_RT","expires_in":3600,"scope":"user-library-read user-library-modify user-read-recently-played user-top-read playlist-read-private playlist-read-collaborative user-follow-read user-read-playback-state user-modify-playback-state"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class LibraryRefreshUnavailableProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
}
