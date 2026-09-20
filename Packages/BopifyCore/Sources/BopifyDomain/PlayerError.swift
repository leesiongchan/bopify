/// The reachable subset of the PRD taxonomy for this slice. Cases for
/// features that do not exist yet are deliberately absent.
public enum PlayerError: Error, Hashable, Sendable {
    case authDenied
    case invalidCallback
    case authExpired
    case premiumRequired
    case networkUnavailable
    case playbackSessionLost
    case unknown

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
