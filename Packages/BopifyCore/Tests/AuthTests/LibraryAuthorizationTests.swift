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
