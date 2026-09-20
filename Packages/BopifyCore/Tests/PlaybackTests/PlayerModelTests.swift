import Testing
import Foundation
@testable import BopifyPlayback
import BopifyDomain

@MainActor
@Suite("PlayerModel")
struct PlayerModelTests {
    private func makeTrack() -> Track {
        Track(uri: SpotifyURI("spotify:track:abc")!, title: "Title",
              artists: [ArtistSummary(name: "Artist")], albumTitle: "Album",
              artwork: nil, durationMs: 240_000)
    }

    /// Emits events and waits for the model's consumer task to fold them in.
    private func settle(_ model: PlayerModel, _ engine: StubPlaybackEngine, _ events: [PlaybackEvent]) async {
        for event in events { engine.emit(event) }
        try? await Task.sleep(for: .milliseconds(50))
    }

    @Test func startsIdle() {
        let model = PlayerModel(engine: StubPlaybackEngine())
        #expect(model.state.phase == .idle)
        #expect(model.state.currentTrack == nil)
    }

    @Test func trackChangedPopulatesMetadataAndDuration() async {
        let engine = StubPlaybackEngine()
        let model = PlayerModel(engine: engine)
        model.start()
        await settle(model, engine, [.trackChanged(makeTrack())])

        #expect(model.state.currentTrack?.title == "Title")
        #expect(model.state.durationMs == 240_000)
        #expect(model.state.canNext)
        #expect(model.state.canPrevious)
    }

    @Test func playingThenPausedMovesThroughPhases() async {
        let engine = StubPlaybackEngine()
        let model = PlayerModel(engine: engine)
        model.start()

        await settle(model, engine, [.playing(positionMs: 1000)])
        #expect(model.state.phase == .playing)
        #expect(model.state.positionMs == 1000)

        await settle(model, engine, [.paused(positionMs: 2000)])
        #expect(model.state.phase == .paused)
        #expect(model.state.positionMs == 2000)
    }

    @Test func bufferingPreservesTheCurrentTrack() async {
        let engine = StubPlaybackEngine()
        let model = PlayerModel(engine: engine)
        model.start()
        await settle(model, engine, [.trackChanged(makeTrack()), .playing(positionMs: 1000), .loading])

        #expect(model.state.phase == .loading)
        #expect(model.state.currentTrack?.title == "Title")  // PLAY-07
    }

    @Test func losingTheActiveDeviceStopsPretendingToPlay() async {
        let engine = StubPlaybackEngine()
        let model = PlayerModel(engine: engine)
        model.start()
        await settle(model, engine, [.trackChanged(makeTrack()), .playing(positionMs: 1000),
                                     .activeDeviceChanged(isActive: false)])

        #expect(model.state.isActiveDevice == false)
        #expect(model.state.phase == .idle)
    }

    @Test func failureSetsErrorAndErrorPhase() async {
        let engine = StubPlaybackEngine()
        let model = PlayerModel(engine: engine)
        model.start()
        await settle(model, engine, [.failed(.premiumRequired)])

        #expect(model.state.phase == .error)
        #expect(model.state.error == .premiumRequired)
    }

    @Test func togglePlayPauseSendsTheCommandButDoesNotAssumeItWorked() async {
        let engine = StubPlaybackEngine()
        let model = PlayerModel(engine: engine)
        model.start()
        await settle(model, engine, [.playing(positionMs: 0)])

        model.togglePlayPause()
        try? await Task.sleep(for: .milliseconds(50))

        #expect(engine.recordedCommands.contains("pause"))
        // Commands are requests. Only an event may change the phase.
        #expect(model.state.phase == .playing)

        await settle(model, engine, [.paused(positionMs: 5)])
        #expect(model.state.phase == .paused)
    }

    @Test func externalPauseFromAnotherDeviceIsReflected() async {
        let engine = StubPlaybackEngine()
        let model = PlayerModel(engine: engine)
        model.start()
        await settle(model, engine, [.playing(positionMs: 0), .paused(positionMs: 900)])

        #expect(model.state.phase == .paused)
        #expect(engine.recordedCommands.isEmpty)  // nobody pressed anything here
    }

    @Test func loadSendsTheContextURIToTheEngine() async {
        let engine = StubPlaybackEngine()
        let model = PlayerModel(engine: engine)
        model.start()

        let request = PlayRequest(contextURI: SpotifyURI("spotify:playlist:xyz")!)
        model.load(request)
        try? await Task.sleep(for: .milliseconds(50))

        #expect(engine.recordedCommands.contains("load:spotify:playlist:xyz"))
    }
}
