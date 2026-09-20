public enum PlaybackPhase: Hashable, Sendable {
    case idle, loading, buffering, playing, paused, ended, error
}

public struct PlaybackState: Hashable, Sendable {
    public var phase: PlaybackPhase = .idle
    public var currentTrack: Track?
    public var positionMs: Int64 = 0
    public var durationMs: Int64 = 0
    public var volume: Double = 1.0
    public var canSeek = false
    public var canPrevious = false
    public var canNext = false
    /// False when another Spotify device has taken over. Without this the
    /// UI would show a phantom paused track indefinitely.
    public var isActiveDevice = false
    public var error: PlayerError?

    public init() {}
}
