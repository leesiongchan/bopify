/// The reachable subset of the PRD taxonomy for this slice. Cases for
/// features that do not exist yet are deliberately absent.
public enum PlayerError: Error, Hashable, Sendable {
    case authDenied
    case invalidCallback
    /// Rust's `AuthInvalid` (-3) means "rejected **or** expired", and the
    /// two are indistinguishable at the boundary. The name follows PRD.md's
    /// taxonomy and is accurate for the Swift-side throws; the user-facing
    /// string deliberately does not promise that signing in again will work.
    case authExpired
    case credentialUnavailable
    case credentialCleanupRequired
    case credentialCleanupNotRecorded
    case credentialAccessDenied
    case credentialCorrupt
    case credentialSaveFailed
    case premiumRequired
    case networkUnavailable
    case playbackSessionLost
    case unknown

    public var canRetryCredentials: Bool {
        switch self {
        case .credentialUnavailable, .credentialAccessDenied, .credentialSaveFailed: true
        default: false
        }
    }

    /// Mirrors the stable codes in the Rust `BopifyError`.
    public init(ffiCode: Int32) {
        switch ffiCode {
        case -2: self = .playbackSessionLost
        case -3: self = .authExpired
        case -4: self = .premiumRequired
        case -5: self = .networkUnavailable
        default: self = .unknown
        }
    }
}
