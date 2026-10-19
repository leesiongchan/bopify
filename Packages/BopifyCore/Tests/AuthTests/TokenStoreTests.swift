import Testing
import Foundation
import Security
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

    @Test(arguments: [errSecInteractionNotAllowed, errSecNotAvailable, errSecAuthFailed, errSecUserCanceled, OSStatus(-9999)])
    func failedReadIsNeverReportedAsMissing(_ status: OSStatus) throws {
        let expected: KeychainError
        switch status {
        case errSecInteractionNotAllowed, errSecNotAvailable: expected = .unavailable(status)
        case errSecAuthFailed, errSecUserCanceled: expected = .accessDenied(status)
        default: expected = .unexpected(status)
        }
        #expect(throws: expected) { try KeychainTokenStore.decode(status: status, item: nil) }
    }

    @Test func onlyMissingItemReturnsNil() throws {
        #expect(try KeychainTokenStore.decode(status: errSecItemNotFound, item: nil) == nil)
        #expect(throws: KeychainError.corrupt) { try KeychainTokenStore.decode(status: errSecSuccess, item: nil) }
        #expect(throws: KeychainError.corrupt) { try KeychainTokenStore.decode(status: errSecSuccess, item: "wrong type" as CFString) }
    }

    @Test func overwritesAnExistingItem() throws {
        let store = makeStore()
        try store.save(sample)
        let updated = TokenSet(accessToken: "AT2", refreshToken: "RT2",
                               expiresAt: sample.expiresAt, grantedScopes: ["streaming"])
        try store.save(updated)
        #expect(try store.load()?.accessToken == "AT2")
        try store.clear()
    }

    @Test func corruptStoredCredentialsAreNotReportedAsMissing() throws {
        let service = "my.bopify.tests.\(UUID().uuidString)"
        let store = KeychainTokenStore(service: service)
        defer { try? store.clear() }
        try store.save(sample)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: "spotify-tokens"]
        #expect(SecItemUpdate(query as CFDictionary, [kSecValueData as String: Data("invalid".utf8)] as CFDictionary) == errSecSuccess)
        #expect(throws: (any Error).self) { _ = try store.load() }
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
        #expect(try playback.load() == sample)
        #expect(try library.load() == libraryToken)
        try library.clear()
        #expect(try playback.load() == sample)
        #expect(try library.load() == nil)
    }
}
