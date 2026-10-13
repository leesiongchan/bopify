import Testing
import Foundation
@testable import BopifyAuth
import BopifyDomain

@Suite("Logout cleanup", .serialized)
struct LogoutIntentTests {
    @Test func failedSignOutBlocksSameActorRestoration() async throws {
        let store = CleanupFaultStore()
        let auth = SpotifyAuthService(clientID: "test", store: store, openURL: { _ in Issue.record("Unexpected browser") })
        #expect(try await auth.validAccessToken() == "OLD")
        await #expect(throws: PlayerError.credentialCleanupRequired) { try await auth.signOut() }
        await #expect(throws: (any Error).self) { _ = try await auth.validAccessToken() }
        #expect(store.load()?.accessToken == "OLD")
    }

    private func withDirectory(_ body: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LogoutIntentTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }

    @Test(arguments: [(false, false), (false, true), (true, false), (true, true)])
    func independentCleanupSurvivesServiceRecreation(_ failures: (Bool, Bool)) async throws {
        try await withDirectory { directory in
            let url = directory.appendingPathComponent("intent.json")
            let intent = LogoutIntentStore(url: url)
            let playback = CleanupFaultStore(), library = CleanupFaultStore()
            playback.failClear = failures.0; library.failClear = failures.1
            try intent.begin([.playback, .library])
            let first = SpotifyAuthService(clientID: "playback", store: playback, logoutIntent: intent)
            let second = SpotifyAuthService(clientID: "library", store: library, logoutIntent: intent, credentialNamespace: .library)
            _ = try? await first.signOut()
            _ = try? await second.signOut()
            let reopened = LogoutIntentStore(url: url)
            #expect(try reopened.isPending(.playback) == failures.0)
            #expect(try reopened.isPending(.library) == failures.1)
            for (store, namespace, failed) in [(playback, CredentialNamespace.playback, failures.0), (library, .library, failures.1)] {
                let restored = SpotifyAuthService(clientID: "recreated", store: store, logoutIntent: reopened, credentialNamespace: namespace)
                if failed {
                    await #expect(throws: PlayerError.credentialCleanupRequired) { _ = try await restored.restore() }
                    await #expect(throws: PlayerError.credentialCleanupRequired) { _ = try await restored.validAccessToken() }
                } else { #expect(try await restored.restore() == nil) }
            }
        }
    }

    @Test func intentBlocksAlreadyLoadedCredentials() async throws {
        try await withDirectory { directory in
            let intent = LogoutIntentStore(url: directory.appendingPathComponent("intent.json"))
            let auth = SpotifyAuthService(clientID: "test", store: CleanupFaultStore(), logoutIntent: intent)
            #expect(try await auth.validAccessToken() == "OLD")
            try intent.begin([.playback, .library])
            await #expect(throws: PlayerError.credentialCleanupRequired) { _ = try await auth.validAccessToken() }
        }
    }

    @Test(arguments: ["invalid", #"{"version":2,"pending":[]}"#, #"{"version":1,"pending":["unknown"]}"#])
    func corruptOrUnknownIntentBlocksRestorationUntilExplicitCleanup(_ contents: String) async throws {
        try await withDirectory { directory in
            let url = directory.appendingPathComponent("intent.json")
            try Data(contents.utf8).write(to: url)
            let intent = LogoutIntentStore(url: url)
            let auth = SpotifyAuthService(clientID: "test", store: CleanupFaultStore(), logoutIntent: intent)
            await #expect(throws: PlayerError.credentialCleanupRequired) { _ = try await auth.restore() }
            try intent.begin([.playback])
            #expect(try intent.isPending(.playback) && intent.isPending(.library))
            #expect(try LogoutIntentStore(url: url).hasPendingCleanup())
        }
    }

    @Test func failedCompletionCommitRetainsPendingBit() async throws {
        try await withDirectory { directory in
            let parent = directory.appendingPathComponent("live")
            let parked = directory.appendingPathComponent("parked")
            let url = parent.appendingPathComponent("intent.json")
            let intent = LogoutIntentStore(url: url)
            try intent.begin([.playback, .library])
            try FileManager.default.moveItem(at: parent, to: parked)
            try Data("obstruction".utf8).write(to: parent)
            #expect(throws: (any Error).self) { try intent.complete(.playback) }
            #expect(try intent.isPending(.playback))
            try FileManager.default.removeItem(at: parent)
            try FileManager.default.moveItem(at: parked, to: parent)
            #expect(try LogoutIntentStore(url: url).isPending(.playback))
            try intent.complete(.playback)
            #expect(try !LogoutIntentStore(url: url).isPending(.playback))
            #expect(try LogoutIntentStore(url: url).isPending(.library))
        }
    }

    @Test func failedIntentCommitStopsDeletionAndKeepsCurrentProcessBlocked() async throws {
        try await withDirectory { directory in
            let parent = directory.appendingPathComponent("live")
            let parked = directory.appendingPathComponent("parked")
            let intent = LogoutIntentStore(url: parent.appendingPathComponent("intent.json"))
            try intent.begin([])
            let store = CleanupFaultStore(); store.failClear = false
            let auth = SpotifyAuthService(clientID: "test", store: store, logoutIntent: intent)
            #expect(try await auth.validAccessToken() == "OLD")
            try FileManager.default.moveItem(at: parent, to: parked)
            try Data("obstruction".utf8).write(to: parent)
            await #expect(throws: (any Error).self) { try await auth.signOut() }
            #expect(store.load()?.accessToken == "OLD")
            await #expect(throws: PlayerError.credentialCleanupRequired) { _ = try await auth.validAccessToken() }
        }
    }

    @Test func cleanupRetryRemovesGrantBeforeAllowingConsent() async throws {
        try await withDirectory { directory in
            let intent = LogoutIntentStore(url: directory.appendingPathComponent("intent.json"))
            let store = CleanupFaultStore()
            let auth = SpotifyAuthService(clientID: "test", store: store, logoutIntent: intent,
                                          openURL: { _ in Issue.record("Cleanup failure must not open browser") })
            await #expect(throws: PlayerError.credentialCleanupRequired) { try await auth.signOut() }
            await #expect(throws: PlayerError.credentialCleanupRequired) { _ = try await auth.signIn() }
            store.failClear = false
            try await auth.signOut()
            #expect(store.load() == nil)
            #expect(try !LogoutIntentStore(url: directory.appendingPathComponent("intent.json")).hasPendingCleanup())
            #expect(try await auth.restore() == nil)
        }
    }

    @Test func explicitConsentAfterCleanupInstallsOnlyTheNewGrant() async throws {
        try await withDirectory { directory in
            let intent = LogoutIntentStore(url: directory.appendingPathComponent("intent.json"))
            let store = CleanupFaultStore()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [CleanupConsentProtocol.self]
            let auth = SpotifyAuthService(clientID: "test", client: TokenClient(clientID: "test", session: URLSession(configuration: configuration)),
                                          store: store, logoutIntent: intent, openURL: { url in
                #expect(store.load() == nil)
                let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
                let callback = URL(string: "\(query["redirect_uri"]!)?code=NEWCODE&state=\(query["state"]!)")!
                Task { _ = try? await URLSession.shared.data(from: callback) }
            })
            await #expect(throws: PlayerError.credentialCleanupRequired) { try await auth.signOut() }
            store.failClear = false
            let grant = try await auth.signIn()
            #expect(grant.accessToken == "NEW")
            #expect(try !intent.hasPendingCleanup())
            let restored = SpotifyAuthService(clientID: "test", store: store,
                logoutIntent: LogoutIntentStore(url: directory.appendingPathComponent("intent.json")))
            #expect(try await restored.validAccessToken() == "NEW")
        }
    }

    @Test(arguments: [false, true])
    func missingClientIDStillAttemptsLibraryCleanup(_ fails: Bool) async throws {
        try await withDirectory { directory in
            let suite = directory.appendingPathComponent("defaults").path
            let store = CleanupFaultStore(); store.failClear = fails
            let intent = LogoutIntentStore(url: directory.appendingPathComponent("intent.json"))
            let library = LibraryAuthorization(suiteName: suite, orphanedStore: store, logoutIntent: intent) { _ in
                Issue.record("No client ID should create no auth actor")
                return SpotifyAuthService(clientID: "unused", store: store)
            }
            if fails {
                await #expect(throws: PlayerError.credentialCleanupRequired) { try await library.signOut() }
                #expect(store.load() != nil)
            } else {
                try await library.signOut()
                #expect(store.load() == nil)
            }
            #expect(try LogoutIntentStore(url: directory.appendingPathComponent("intent.json")).isPending(.library) == fails)
        }
    }

}

private final class CleanupFaultStore: TokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: TokenSet? = TokenSet(accessToken: "OLD", refreshToken: "RT", expiresAt: .now.addingTimeInterval(3600), grantedScopes: ["streaming", "user-library-read"])
    private var fails = true
    var failClear: Bool {
        get { lock.withLock { fails } }
        set { lock.withLock { fails = newValue } }
    }
    func save(_ value: TokenSet) { lock.withLock { tokens = value } }
    func load() -> TokenSet? { lock.withLock { tokens } }
    func clear() throws {
        try lock.withLock {
            if fails { throw KeychainError.unavailable(-25308) }
            tokens = nil
        }
    }
}

private final class CleanupConsentProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let data = Data(#"{"access_token":"NEW","refresh_token":"NEW_RT","expires_in":3600,"scope":"streaming"}"#.utf8)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
