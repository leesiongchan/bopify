import Foundation
import Security

public enum SoloistKeyError: Error, Sendable { case invalid, unavailable }

public protocol SoloistKeyStoring: Sendable {
    func load() throws -> String?
    func save(_ key: String) throws
    func clear() throws
}

/// Separate from OAuth grants: ordinary engine switches preserve this personal key.
public struct SoloistKeyStore: SoloistKeyStoring {
    public init() {}
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.leesiongchan.bopify.soloist",
         kSecAttrAccount as String: "api-key"]
    }

    public static func validated(_ raw: String) throws -> String {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.count <= 4096,
              key.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !$0.properties.isWhitespace }) else {
            throw SoloistKeyError.invalid
        }
        return key
    }

    public func load() throws -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { throw SoloistKeyError.unavailable }
        return try Self.validated(value)
    }

    public func save(_ key: String) throws {
        let data = Data(try Self.validated(key).utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else { throw SoloistKeyError.unavailable }
        } else if status != errSecSuccess { throw SoloistKeyError.unavailable }
    }

    public func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SoloistKeyError.unavailable }
    }
}
