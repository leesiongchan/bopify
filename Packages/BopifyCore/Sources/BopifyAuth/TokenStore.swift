import Foundation
import Security
import os
import BopifyDomain

public protocol TokenStoring: Sendable {
    func save(_ tokens: TokenSet) throws
    func load() throws -> TokenSet?
    func clear() throws
}

/// Keep the existing file-based Keychain identity so installed users retain
/// their saved grant; changing Keychain implementations requires a migration.
public struct KeychainTokenStore: TokenStoring {
    private let service: String
    private let account = "spotify-tokens"

    public init(service: String = "com.leesiongchan.bopify") { self.service = service }

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

    public func load() throws -> TokenSet? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return try Self.decode(status: status, item: item)
    }

    // Only absence is a signed-out state; storage and decoding failures preserve the grant.
    static func decode(status: OSStatus, item: CFTypeRef?) throws -> TokenSet? {
        if status == errSecItemNotFound {
            BopifyLog.keychain.debug("load found nothing stored")
            return nil
        }
        guard status == errSecSuccess else {
            BopifyLog.keychain.error("load failed status=\(status, privacy: .public)")
            switch status {
            case errSecInteractionNotAllowed, errSecNotAvailable: throw KeychainError.unavailable(status)
            case errSecAuthFailed, errSecUserCanceled: throw KeychainError.accessDenied(status)
            default: throw KeychainError.unexpected(status)
            }
        }
        guard let data = item as? Data,
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            BopifyLog.keychain.error("load found a stored token set that could not be decoded")
            throw KeychainError.corrupt
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

public enum KeychainError: Error, Hashable, Sendable {
    case unavailable(OSStatus)
    case accessDenied(OSStatus)
    case corrupt
    case unexpected(OSStatus)
}
