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
/// surface. kSecUseDataProtectionKeychain is omitted because, under local
/// development signing with no provisioning profile, it fails every
/// operation with errSecMissingEntitlement (-34018) per TN3137 -- this
/// falls back to the legacy file-based keychain until the app target
/// carries proper entitlements.
public struct KeychainTokenStore: TokenStoring {
    private let service: String
    private let account = "spotify-tokens"

    public init(service: String = "my.bopify.tokens") { self.service = service }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func save(_ tokens: TokenSet) throws {
        let data = try JSONEncoder().encode(Stored(tokens))
        let status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = baseQuery
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
        var query = baseQuery
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
        let status = SecItemDelete(baseQuery as CFDictionary)
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
