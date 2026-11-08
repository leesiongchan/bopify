import Testing
import BopifyDomain
import BopifyPlayback

@MainActor @Suite("Preview discovery playback")
struct PreviewDiscoveryPlaybackTests {
    private let first = liveLyricTrack(SpotifyURI("spotify:track:first")!)
    private let second = liveLyricTrack(SpotifyURI("spotify:track:second")!)
    private let third = liveLyricTrack(SpotifyURI("spotify:track:third")!)

    @Test func directSelectionStartsTheChosenSong() async throws {
        let engine = PreviewPlaybackEngine(tracks: [first, second, third])
        let player = PlayerModel(engine: engine)
        player.start()
        defer { player.stop() }
        try await engine.load(PlayRequest(contextURI: second.uri))
        try await liveLyricEventually { player.state.phase == .playing }
        #expect(player.state.currentTrack?.uri == second.uri)
    }

    @Test func nextFollowsTheRecommendationOrder() async throws {
        let engine = PreviewPlaybackEngine(tracks: [first, second, third])
        let player = PlayerModel(engine: engine)
        player.start()
        defer { player.stop() }
        try await engine.load(PlayRequest(contextURI: first.uri, followingTrackURIs: [third.uri, second.uri]))
        try await liveLyricEventually { player.state.phase == .playing }
        #expect(player.state.queue?.next.map(\.uri) == [third.uri, second.uri])
        try await engine.next()
        try await liveLyricEventually { player.state.currentTrack?.uri != first.uri }
        #expect(player.state.currentTrack?.uri == third.uri)
    }
}
