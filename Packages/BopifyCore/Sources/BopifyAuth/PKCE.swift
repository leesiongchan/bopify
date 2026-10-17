import AppAuthCore

public struct PKCEPair: Sendable {
    public let verifier: String
    public let challenge: String

    public init(verifier: String) {
        self.verifier = verifier
        self.challenge = OIDAuthorizationRequest.codeChallengeS256(forVerifier: verifier)!
    }

    public static func random() -> PKCEPair {
        PKCEPair(verifier: OIDAuthorizationRequest.generateCodeVerifier()!)
    }
}
