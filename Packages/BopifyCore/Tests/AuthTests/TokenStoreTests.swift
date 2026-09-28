import Testing
import Foundation
@testable import BopifyAuth
import BopifyDomain

@Suite("KeychainTokenStore", .serialized)
struct TokenStoreTests {
    private func makeStore() -> KeychainTokenStore {
        KeychainTokenStore(service: "my.bopify.tests.\(UUID().uuidString)")
    }

    private var sample: TokenSet {
        TokenSet(accessToken: "AT", refreshToken: "RT",
                 expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
                 grantedScopes: ["streaming"])
    }

    @Test func roundTripsATokenSet() throws {
        let store = makeStore()
        try store.save(sample)
        let loaded = try #require(store.load())
        #expect(loaded == sample)
        try store.clear()
    }

    @Test func overwritesAnExistingItem() throws {
        let store = makeStore()
        try store.save(sample)
        let updated = TokenSet(accessToken: "AT2", refreshToken: "RT2",
                               expiresAt: sample.expiresAt, grantedScopes: ["streaming"])
        try store.save(updated)
        #expect(store.load()?.accessToken == "AT2")
        try store.clear()
    }

    @Test func returnsNilWhenNothingIsStored() {
        #expect(makeStore().load() == nil)
    }

    @Test func clearRemovesTheItem() throws {
        let store = makeStore()
        try store.save(sample)
        try store.clear()
        #expect(store.load() == nil)
    }

    @Test func clearOnAnEmptyStoreIsNotAnError() throws {
        try makeStore().clear()
    }

    @Test func separateKeychainServicesDoNotOverwriteEachOther() throws {
        let prefix = "my.bopify.tests.\(UUID().uuidString)"
        let playback = KeychainTokenStore(service: prefix)
        let library = KeychainTokenStore(service: prefix + ".library")
        defer { try? playback.clear(); try? library.clear() }
        let libraryToken = TokenSet(accessToken: "LIBRARY", refreshToken: "LIBRARY_RT",
                                    expiresAt: sample.expiresAt, grantedScopes: ["user-library-read"])
        try playback.save(sample)
        try library.save(libraryToken)
        #expect(playback.load() == sample)
        #expect(library.load() == libraryToken)
        try library.clear()
        #expect(playback.load() == sample)
        #expect(library.load() == nil)
    }

    @Test func migratesLegacyItemAndDoesNotRestoreItAfterSignOut() throws {
        let prefix = "my.bopify.tests.\(UUID().uuidString)"
        let old = KeychainTokenStore(service: prefix + ".old")
        let current = KeychainTokenStore(service: prefix + ".new", migratingFrom: prefix + ".old")
        defer { try? old.clear(); try? current.clear() }
        try old.save(sample)

        #expect(current.load() == sample)
        #expect(old.load() == nil)
        try current.clear()
        try old.save(sample)
        #expect(current.load() == nil)
    }
}
