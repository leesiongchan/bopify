import Foundation
import Testing
import BopifyDomain
@testable import BopifyPlayback

@Suite("Now Playing info")
struct NowPlayingInfoTests {
    let track = Track(uri: SpotifyURI("spotify:track:a")!, title: "Night Bloom",
                      artists: [ArtistSummary(name: "The Lanterns"), ArtistSummary(name: "Odile")],
                      albumTitle: "Lanterns", artwork: Artwork(url: URL(string: "https://i.scdn.co/image/a")!),
                      durationMs: 187_000)

    func state(_ phase: PlaybackPhase, active: Bool = true, track: Track?) -> PlaybackState {
        var state = PlaybackState()
        state.phase = phase
        state.isActiveDevice = active
        state.currentTrack = track
        state.durationMs = track?.durationMs ?? 0
        state.canNext = true
        state.canPrevious = true
        state.canSeek = true
        return state
    }

    @Test func unreadyPlayerReleasesNowPlaying() {
        #expect(nowPlayingInfo(for: state(.playing, track: track), positionMs: 12_000, connectionReady: false) == nil)
    }

    @Test func playingClaimsNowPlayingWithTheTrack() {
        let info = nowPlayingInfo(for: state(.playing, track: track), positionMs: 64_000)
        #expect(info == NowPlayingInfo(title: "Night Bloom", artist: "The Lanterns, Odile", album: "Lanterns",
                                       artworkURL: URL(string: "https://i.scdn.co/image/a"), durationMs: 187_000,
                                       elapsedMs: 64_000, isPlaying: true, canNext: true, canPrevious: true, canSeek: true))
    }

    @Test(arguments: [PlaybackPhase.paused, .loading, .buffering, .ended, .error(.networkUnavailable)])
    func otherPhasesOnThisDeviceReportPausedAndKeepTheTrack(_ phase: PlaybackPhase) {
        let info = nowPlayingInfo(for: state(phase, track: track), positionMs: 1_000)
        #expect(info?.isPlaying == false)
        #expect(info?.title == "Night Bloom")
    }

    @Test func anotherDevicePlayingStepsAside() {
        var mirroring = state(.idle, active: false, track: track)
        mirroring.remote = RemotePlayback(deviceName: "Kitchen Speaker", trackURI: track.uri, track: track,
                                          isPlaying: true, positionMs: 0, durationMs: track.durationMs)
        #expect(nowPlayingInfo(for: mirroring, positionMs: 0) == nil)
    }

    @Test func noTrackStepsAside() {
        #expect(nowPlayingInfo(for: state(.idle, track: nil), positionMs: 0) == nil)
    }

    @Test func missingArtworkAndAlbumStayEmpty() {
        let bare = Track(uri: track.uri, title: "Night Bloom", artists: [], albumTitle: nil, artwork: nil, durationMs: 1_000)
        let info = nowPlayingInfo(for: state(.playing, track: bare), positionMs: 0)
        #expect(info?.artworkURL == nil)
        #expect(info?.album == nil)
        #expect(info?.artist == "")
    }

    @Test func availabilityFollowsThePlayer() {
        var limited = state(.playing, track: track)
        limited.canNext = false
        limited.canPrevious = false
        limited.canSeek = false
        let info = nowPlayingInfo(for: limited, positionMs: 0)
        #expect(info?.canNext == false)
        #expect(info?.canPrevious == false)
        #expect(info?.canSeek == false)
    }

    @Test func seekingNeedsAKnownDuration() {
        var unknown = state(.playing, track: track)
        unknown.durationMs = 0
        #expect(nowPlayingInfo(for: unknown, positionMs: 0)?.canSeek == false)
    }
}
