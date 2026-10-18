public struct PlayRequest: Hashable, Sendable {
    public let contextURI: SpotifyURI
    public let startTrackURI: SpotifyURI?
    public let startPositionMs: Int64

    public init(contextURI: SpotifyURI, startTrackURI: SpotifyURI? = nil, startPositionMs: Int64 = 0) {
        self.contextURI = contextURI
        self.startTrackURI = startTrackURI
        self.startPositionMs = startPositionMs
    }
}

/// The only seam between the app and librespot. The engine emits events
/// and never exposes state: as a Connect device, another client can pause
/// or skip us, so state is observed rather than told.
public protocol PlaybackEngine: Sendable {
    var events: AsyncStream<PlaybackEvent> { get }

    func load(_ request: PlayRequest) async throws
    func resume() async throws
    /// Plays on this Mac while another device, or none, owns the session.
    func playHere() async throws
    func pause() async throws
    func next() async throws
    func previous() async throws
    func seek(to milliseconds: Int64) async throws
    func setVolume(_ value: Double) async throws
    func selectQueueEntry(_ target: QueueTarget) async throws
    func setShuffle(_ enabled: Bool) async throws
    func setRepeat(_ mode: RepeatMode) async throws
    /// Spotify's radio for a track or artist seed. Throws `RadioFailure` when Spotify has none.
    func requestRadio(seed: SpotifyURI) async throws -> RadioMix
    /// Spotify lyrics for one track. Throws `LyricFailure` for lyric-service failures.
    func requestLyrics(for track: SpotifyURI) async throws -> TrackLyrics
    /// The main artist's popular songs for one track, ordered by Spotify.
    func requestArtistTopTracks(for track: SpotifyURI) async throws -> ArtistTopTracks
}

extension PlaybackEngine {
    public func requestArtistTopTracks(for track: SpotifyURI) async throws -> ArtistTopTracks {
        throw ArtistTopTracksFailure.unavailable
    }
}
