import Foundation
import Security
import BopifyDomain

public protocol TokenStoring: Sendable {
    func save(_ tokens: TokenSet) throws
    func load() -> TokenSet?
    func clear() throws
}

/// Direct SecItem. No maintained Swift wrapper sets
/// kSecUseDataProtectionKeychain, which Apple recommends for all keychain
/// operations, and the whole surface is about sixty lines.
///
/// kSecUseDataProtectionKeychain is omitted: under local development
/// signing (no provisioning profile yet, per TN3137) it fails every
/// operation with errSecMissingEntitlement (-34018). This falls back to
/// the legacy file-based keychain until the app target carries proper
/// entitlements.
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
            guard addStatus == errSecSuccess else { throw KeychainError.unexpected(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.unexpected(status)
        }
    }

    public func load() -> TokenSet? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return nil }
        return stored.tokenSet
    }

    public func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.unexpected(status) }
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
