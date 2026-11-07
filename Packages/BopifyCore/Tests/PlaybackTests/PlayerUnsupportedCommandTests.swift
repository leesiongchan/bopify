import Testing
import BopifyDomain
@testable import BopifyPlayback

@MainActor
@Suite("Unavailable playback actions")
struct PlayerUnsupportedCommandTests {
    @Test(arguments: ["volume", "shuffle"])
    func unsupportedActionsDescribeTheAvailableEngine(action: String) async throws {
        let model = PlayerModel(engine: UnsupportedCommandEngine())
        model.start()
        defer { model.stop() }
        for _ in 0..<10_000 { if model.state.isActiveDevice { break }; await Task.yield() }
        try #require(model.state.isActiveDevice)
        if action == "volume" {
            model.setVolume(0.25)
            model.endVolumeEditing()
        } else {
            model.setShuffle(true)
        }
        for _ in 0..<10_000 { if model.commandNotice != nil { break }; await Task.yield() }
        #expect(model.commandNotice == "This action is unavailable with Soloist.")
        #expect(model.isEngineReady)
    }
}

private struct UnsupportedCommandEngine: PlaybackEngine {
    let events = AsyncStream<PlaybackEvent> { $0.yield(.playing(positionMs: 0)) }
    func load(_ request: PlayRequest) async throws { throw SoloistPlaybackError.unsupported }
    func resume() async throws { throw SoloistPlaybackError.unsupported }
    func playHere() async throws { throw SoloistPlaybackError.unsupported }
    func pause() async throws { throw SoloistPlaybackError.unsupported }
    func next() async throws { throw SoloistPlaybackError.unsupported }
    func previous() async throws { throw SoloistPlaybackError.unsupported }
    func seek(to milliseconds: Int64) async throws { throw SoloistPlaybackError.unsupported }
    func setVolume(_ value: Double) async throws { throw SoloistPlaybackError.unsupported }
    func selectQueueEntry(_ target: QueueTarget) async throws { throw SoloistPlaybackError.unsupported }
    func setShuffle(_ enabled: Bool) async throws { throw SoloistPlaybackError.unsupported }
    func setRepeat(_ mode: RepeatMode) async throws { throw SoloistPlaybackError.unsupported }
    func requestRadio(seed: SpotifyURI) async throws -> RadioMix { throw RadioFailure.unavailable }
    func requestLyrics(for track: SpotifyURI) async throws -> TrackLyrics { throw LyricFailure.unavailable }
    func requestArtistTopTracks(for track: SpotifyURI, artistIndex: Int) async throws -> ArtistTopTracks {
        throw ArtistTopTracksFailure.unavailable
    }
}
