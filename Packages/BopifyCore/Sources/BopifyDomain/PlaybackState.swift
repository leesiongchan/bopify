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

/// What another Connect device is playing while Bopify is inactive.
public struct RemotePlayback: Hashable, Sendable {
    public let deviceName: String
    public let trackURI: SpotifyURI
    /// Nil when the metadata lookup failed.
    public let track: Track?
    public let isPlaying: Bool
    /// As of the event's receipt; the player model interpolates from there.
    public let positionMs: Int64
    public let durationMs: Int64

    public init(deviceName: String, trackURI: SpotifyURI, track: Track?,
                isPlaying: Bool, positionMs: Int64, durationMs: Int64) {
        self.deviceName = deviceName; self.trackURI = trackURI; self.track = track
        self.isPlaying = isPlaying; self.positionMs = positionMs; self.durationMs = durationMs
    }
}

public enum PlaybackPhase: Hashable, Sendable {
    case idle, loading, playing, paused, ended
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
    /// Another device's live playback. Always nil while Bopify is the active device.
    public var remote: RemotePlayback?
    /// The last mirror after its device stopped, kept because Play resumes that session. Always nil while Bopify is active.
    public var staleRemote: RemotePlayback?
    /// What the record shows while Bopify is inactive, if another device was mirrored.
    public var mirror: RemotePlayback? { remote ?? staleRemote }

    public init() {}
}
