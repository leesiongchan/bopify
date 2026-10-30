public enum PlayerError: Error, Hashable, Sendable {
    case authDenied
    case invalidCallback
    /// Rust's `AuthInvalid` (-3) cannot tell a rejected token from an expired one, so the user-facing string does not
    /// promise that signing in again will work.
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
