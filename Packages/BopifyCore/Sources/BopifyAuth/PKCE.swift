import CryptoKit
import Foundation
import Security

public struct PKCEPair: Sendable {
    public let verifier: String
    public let challenge: String

    public init(verifier: String) {
        self.verifier = verifier
        let digest = SHA256.hash(data: Data(verifier.utf8))
        self.challenge = Data(digest).base64URLEncodedString()
    }

    public static func random() -> PKCEPair {
        var bytes = [UInt8](repeating: 0, count: 64)
        // SecRandomCopyBytes is the platform CSPRNG; PKCE security rests on it.
        precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess)
        return PKCEPair(verifier: Data(bytes).base64URLEncodedString())
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
