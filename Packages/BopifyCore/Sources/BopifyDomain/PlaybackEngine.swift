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
    func pause() async throws
    func next() async throws
    func previous() async throws
    func seek(to milliseconds: Int64) async throws
    func setVolume(_ value: Double) async throws
    func selectQueueEntry(_ target: QueueTarget) async throws
    func setShuffle(_ enabled: Bool) async throws
    func setRepeat(_ mode: RepeatMode) async throws
}
