/// What the engine did at connect time with the account's last session.
public enum StartupOutcome: Hashable, Sendable {
    case restored, likedSongs, nothing
    case remote(deviceName: String)
}

/// Pending until the engine's one startup event, so the UI can show loading
/// rather than "Nothing playing" while the session is restored.
public enum StartupPhase: Hashable, Sendable {
    case pending
    case resolved(StartupOutcome)
}

public enum PlaybackPhase: Hashable, Sendable {
    case idle, loading, buffering, playing, paused, ended
    case error(PlayerError)
}

public struct PlaybackState: Hashable, Sendable {
    public var phase: PlaybackPhase = .idle
    public var queue: PlaybackQueue?
    public var shuffleEnabled = false
    public var repeatMode: RepeatMode = .off
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
    public var startup: StartupPhase = .pending

    public init() {}
}
