import Testing
import Foundation
@testable import BopifyAuth
import BopifyDomain

@Suite("LibraryAuthorization", .serialized)
struct LibraryAuthorizationTests {
    private let id = "25bbd3bacca4412b80f17b892072af71"
    private let other = "0123456789abcdef0123456789abcdef"

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "LibraryAuthorizationTests.\(UUID().uuidString)")!
    }

    private func grant() -> TokenSet {
        TokenSet(accessToken: "LIBRARY", refreshToken: "LIBRARY_RT",
                 expiresAt: Date().addingTimeInterval(3600), grantedScopes: ["user-library-read"])
    }

    private func authorization(_ defaults: UserDefaults, store: InMemoryTokenStore) -> LibraryAuthorization {
        LibraryAuthorization(defaults: defaults) { clientID in
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

    @Test func ignoresAnInvalidStoredID() {
        let defaults = freshDefaults()
        defaults.set("not-an-id", forKey: LibraryAuthorization.defaultsKey)
        #expect(LibraryAuthorization.storedClientID(in: defaults) == nil)
    }

    @Test func missingIDRequiresAuthorization() async {
        let library = authorization(freshDefaults(), store: InMemoryTokenStore())
        await #expect(throws: LibraryError.authorizationRequired) {
            try await library.validAccessToken(requiredScopes: ["user-library-read"])
        }
        await #expect(throws: LibraryError.authorizationRequired) {
            try await library.authorize(["user-library-read"])
        }
    }

    @Test func storedIDServesItsGrant() async throws {
        let defaults = freshDefaults()
        defaults.set(id, forKey: LibraryAuthorization.defaultsKey)
        let store = InMemoryTokenStore()
        try store.save(grant())
        let library = authorization(defaults, store: store)
        #expect(try await library.validAccessToken(requiredScopes: ["user-library-read"]) == "LIBRARY")
    }

    @Test func settingAnIDPersistsItAndClearsAnyEarlierGrant() async throws {
        let defaults = freshDefaults()
        let store = InMemoryTokenStore()
        try store.save(grant())  // left behind by a client the app no longer knows
        let library = authorization(defaults, store: store)
        #expect(try await library.setClientID(id.uppercased()) == id)
        #expect(defaults.string(forKey: LibraryAuthorization.defaultsKey) == id)
        #expect(store.load() == nil)
    }

    @Test func replacingTheIDClearsTheGrant() async throws {
        let defaults = freshDefaults()
        defaults.set(id, forKey: LibraryAuthorization.defaultsKey)
        let store = InMemoryTokenStore()
        try store.save(grant())
        let library = authorization(defaults, store: store)
        _ = try await library.setClientID(other)
        #expect(store.load() == nil)
        await #expect(throws: LibraryError.authorizationRequired) {
            try await library.validAccessToken(requiredScopes: ["user-library-read"])
        }
    }

    /// `cancelPendingWork()` alone would leave the old service holding its in-memory grant.
    @Test func replacingTheIDSignsOutTheOldClient() async throws {
        let defaults = freshDefaults()
        defaults.set(id, forKey: LibraryAuthorization.defaultsKey)
        let store = InMemoryTokenStore()
        try store.save(grant())
        let created = CreatedServices()
        let library = LibraryAuthorization(defaults: defaults) { clientID in
            created.record(SpotifyAuthService(clientID: clientID, store: store, openURL: { _ in }))
        }
        let old = try #require(created.first)
        #expect(try await old.validAccessToken(requiredScopes: ["user-library-read"]) == "LIBRARY")
        _ = try await library.setClientID(other)
        await #expect(throws: LibraryError.authorizationRequired) {
            try await old.validAccessToken(requiredScopes: ["user-library-read"])
        }
    }

    @Test func savingTheSameIDKeepsTheGrant() async throws {
        let defaults = freshDefaults()
        defaults.set(id, forKey: LibraryAuthorization.defaultsKey)
        let store = InMemoryTokenStore()
        try store.save(grant())
        let library = authorization(defaults, store: store)
        _ = try await library.setClientID(" \(id.uppercased()) ")
        #expect(store.load() != nil)
    }

    @Test func invalidIDLeavesStateUntouched() async throws {
        let defaults = freshDefaults()
        defaults.set(id, forKey: LibraryAuthorization.defaultsKey)
        let store = InMemoryTokenStore()
        try store.save(grant())
        let library = authorization(defaults, store: store)
        await #expect(throws: LibraryClientIDError.invalid) { try await library.setClientID("nope") }
        #expect(defaults.string(forKey: LibraryAuthorization.defaultsKey) == id)
        #expect(store.load() != nil)
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
