import Foundation
import Security
import os
import BopifyDomain

public protocol TokenStoring: Sendable {
    func save(_ tokens: TokenSet) throws
    func load() -> TokenSet?
    func clear() throws
}

/// Direct SecItem: no maintained Swift wrapper is needed for a ~60-line
/// surface. kSecUseDataProtectionKeychain is omitted because, per TN3137,
/// it needs an application-identifier entitlement that only team signing
/// grants; the app ships ad-hoc signed, so it would fail every operation
/// with errSecMissingEntitlement (-34018). Revisit only if Bopify is ever
/// signed with a real team.
public struct KeychainTokenStore: TokenStoring {
    private let service: String
    private let legacyService: String?
    private let account = "spotify-tokens"

    public init(service: String = "com.leesiongchan.bopify", migratingFrom legacyService: String? = nil) {
        self.service = service
        self.legacyService = legacyService
    }

    private func baseQuery(for service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func save(_ tokens: TokenSet) throws {
        let data = try JSONEncoder().encode(Stored(tokens))
        let query = baseQuery(for: service)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                BopifyLog.keychain.error("save failed status=\(addStatus, privacy: .public)")
                throw KeychainError.unexpected(addStatus)
            }
        } else if status != errSecSuccess {
            BopifyLog.keychain.error("save failed status=\(status, privacy: .public)")
            throw KeychainError.unexpected(status)
        }
        BopifyLog.keychain.debug("save succeeded")
    }

    public func load() -> TokenSet? {
        if let current = load(from: service) { return current }
        guard let legacyService,
              !UserDefaults.standard.bool(forKey: migrationKey),
              let legacy = load(from: legacyService) else { return nil }
        do {
            try save(legacy)
            UserDefaults.standard.set(true, forKey: migrationKey)
            try delete(from: legacyService)
            BopifyLog.keychain.info("legacy token migrated")
        } catch {
            BopifyLog.keychain.error("legacy token migration failed")
        }
        return legacy
    }

    private var migrationKey: String { "keychain.migrated.\(service)" }

    private func load(from service: String) -> TokenSet? {
        var query = baseQuery(for: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                BopifyLog.keychain.debug("load found nothing stored")
            } else {
                BopifyLog.keychain.error("load failed status=\(status, privacy: .public)")
            }
            return nil
        }
        guard let data = item as? Data,
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            BopifyLog.keychain.error("load found a stored token set that could not be decoded")
            return nil
        }
        BopifyLog.keychain.debug("load succeeded")
        return stored.tokenSet
    }

    public func clear() throws {
        if let legacyService {
            UserDefaults.standard.set(true, forKey: migrationKey)
            do { try delete(from: legacyService) }
            catch { BopifyLog.keychain.error("legacy token clear failed") }
        }
        try delete(from: service)
    }

    private func delete(from service: String) throws {
        let status = SecItemDelete(baseQuery(for: service) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            BopifyLog.keychain.error("clear failed status=\(status, privacy: .public)")
            throw KeychainError.unexpected(status)
        }
        BopifyLog.keychain.debug("clear succeeded")
    }

    private struct Stored: Codable {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Date
        let grantedScopes: [String]

        init(_ tokens: TokenSet) {
            accessToken = tokens.accessToken; refreshToken = tokens.refreshToken
            expiresAt = tokens.expiresAt; grantedScopes = Array(tokens.grantedScopes)
        }
        var tokenSet: TokenSet {
            TokenSet(accessToken: accessToken, refreshToken: refreshToken,
                     expiresAt: expiresAt, grantedScopes: Set(grantedScopes))
        }
    }
}

public enum KeychainError: Error, Hashable, Sendable { case unexpected(OSStatus) }
