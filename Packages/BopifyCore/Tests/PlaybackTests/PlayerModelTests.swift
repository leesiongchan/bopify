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

    @Test func seekIsClampedWithoutPretendingItSucceeded() async {
        let engine = StubPlaybackEngine()
        let model = PlayerModel(engine: engine)
        model.start()
        defer { model.stop() }
        await settle(model, engine, [.trackChanged(makeTrack()), .paused(positionMs: 20_000)])
        model.seek(to: 900_000)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(engine.recordedCommands == ["seek:240000"])
        #expect(model.state.positionMs == 20_000)
        #expect(model.state.phase == .paused)
    }
    @Test func modesWaitForEngineEventsAndRapidCommandsKeepOrder() async {
        let engine = StubPlaybackEngine()
        let model = PlayerModel(engine: engine)
        model.start()
        defer { model.stop() }
        await settle(model, engine, [.trackChanged(makeTrack()), .playing(positionMs: 1000)])
        model.next()
        model.previous()
        model.next()
        model.setShuffle(true)
        model.setRepeat(.track)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(engine.recordedCommands == ["next", "previous", "next", "setShuffle:true", "setRepeat:track"])
        #expect(!model.state.shuffleEnabled)
        #expect(model.state.repeatMode == .off)
    }
    @Test func inactiveAndObsoleteTargetsNeverReachTheEngine() async {
        let engine = StubPlaybackEngine()
        let model = PlayerModel(engine: engine)
        model.start()
        defer { model.stop() }
        model.seek(to: 1000)
        model.next()
        let target = QueueTarget(generation: 12, rawNextIndex: 0)
        await settle(model, engine, [.playing(positionMs: 1000), .queueChanged(PlaybackQueue(generation: 13, previous: [], current: nil, next: []))])
        model.selectQueueEntry(target)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(engine.recordedCommands.isEmpty)
    }
    @Test func stoppingCancelsCommandsThatHaveNotStarted() async {
        let engine = StubPlaybackEngine()
        let model = PlayerModel(engine: engine)
        model.start()
        await settle(model, engine, [.trackChanged(makeTrack()), .playing(positionMs: 0)])
        model.next()
        model.previous()
        model.stop()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(engine.recordedCommands.isEmpty)
    }

    @Test func obsoleteQueueMetadataCannotReplaceANewerSnapshot() async {
        let engine = StubPlaybackEngine()
        let model = PlayerModel(engine: engine)
        model.start()
        defer { model.stop() }
        let entry = QueueEntry(id: "a", uri: makeTrack().uri, target: QueueTarget(generation: 13, rawNextIndex: 0), track: nil, metadataFailed: false)
        await settle(model, engine, [.queueChanged(PlaybackQueue(generation: 13, previous: [], current: nil, next: [entry])), .queueMetadata(generation: 12, entryID: "a", track: makeTrack())])
        #expect(model.state.queue?.next[0].track == nil)
        await settle(model, engine, [.queueMetadata(generation: 13, entryID: "a", track: makeTrack())])
        #expect(model.state.queue?.next[0].track == makeTrack())
        #expect(model.state.currentTrack == nil)
    }
    @Test func rejectionAndPlaybackModesAreObservedWithoutStoppingPlayback() async {
        let engine = StubPlaybackEngine()
        let model = PlayerModel(engine: engine)
        model.start()
        defer { model.stop() }
        await settle(model, engine, [.playing(positionMs: 1000), .shuffleChanged(true), .repeatChanged(.track), .commandRejected("staleQueue")])
        #expect(model.state.shuffleEnabled)
        #expect(model.state.repeatMode == .track)
        #expect(model.state.phase == .playing)
        #expect(model.commandNotice != nil)
    }

    @Test func startsIdle() {
        let model = PlayerModel(engine: StubPlaybackEngine())
        #expect(model.state.phase == .idle)
        #expect(model.state.currentTrack == nil)
    }

    @Test func displayPositionAdvancesOnlyWhilePlayingAndStopsAtDuration() async {
        let engine = StubPlaybackEngine()
        let model = PlayerModel(engine: engine)
        model.start()
        defer { model.stop() }
        await settle(model, engine, [.trackChanged(makeTrack()), .playing(positionMs: 1000)])

        let anchor = model.positionUpdatedAt
        #expect(model.displayPositionMs(at: anchor.addingTimeInterval(2)) == 3000)
        #expect(model.displayPositionMs(at: anchor.addingTimeInterval(300)) == 240_000)
        #expect(model.displayPositionMs(at: anchor.addingTimeInterval(-2)) == 1000)
        #expect(model.state.positionMs == 1000)

        await settle(model, engine, [.paused(positionMs: 4000)])
        #expect(model.displayPositionMs(at: model.positionUpdatedAt.addingTimeInterval(20)) == 4000)
    }

    @Test(arguments: [PlaybackEvent.activeDeviceChanged(isActive: false), .loading, .failed(.networkUnavailable)])
    func interruptionFreezesTheDisplayedPositionUntilAnAuthoritativeUpdate(_ event: PlaybackEvent) async {
        let engine = StubPlaybackEngine()
        let model = PlayerModel(engine: engine)
        model.start()
        defer { model.stop() }
        await settle(model, engine, [.trackChanged(makeTrack()), .playing(positionMs: 1000)])
        let before = model.displayPositionMs(at: .now)
        #expect(before > 1000)

        await settle(model, engine, [event])
        let frozen = model.displayPositionMs(at: .now)
        #expect(frozen >= before)
        #expect(model.displayPositionMs(at: .now.addingTimeInterval(60)) == frozen)
        #expect(model.state.positionMs == 1000)

        await settle(model, engine, [.positionCorrection(positionMs: 4000)])
        #expect(model.displayPositionMs(at: .now) == 4000)
        await settle(model, engine, [.playing(positionMs: 5000)])
        #expect(model.displayPositionMs(at: model.positionUpdatedAt.addingTimeInterval(2)) == 7000)
    }

    @Test func positionCorrectionsReanchorTheDisplayClock() async {
        let engine = StubPlaybackEngine()
        let model = PlayerModel(engine: engine)
        model.start()
        defer { model.stop() }
        await settle(model, engine, [.trackChanged(makeTrack()), .playing(positionMs: 1000)])
        await settle(model, engine, [.positionCorrection(positionMs: 10_000)])

        #expect(model.displayPositionMs(at: model.positionUpdatedAt.addingTimeInterval(2)) == 12_000)
        await settle(model, engine, [.seeked(positionMs: 30_000)])
        #expect(model.displayPositionMs(at: model.positionUpdatedAt.addingTimeInterval(1)) == 31_000)
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

    @Test func loadingPreservesTheCurrentTrack() async {
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

        #expect(model.state.phase == .error(.premiumRequired))
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

    @Test func recoveringFromFailureClearsTheStaleError() async {
        let engine = StubPlaybackEngine()
        let model = PlayerModel(engine: engine)
        model.start()
        await settle(model, engine, [.failed(.networkUnavailable)])

        #expect(model.state.phase == .error(.networkUnavailable))

        await settle(model, engine, [.paused(positionMs: 900)])
        #expect(model.state.phase == .paused)
    }

    @Test func metadataArrivingDoesNotClearAFailure() async {
        let engine = StubPlaybackEngine()
        let model = PlayerModel(engine: engine)
        model.start()
        await settle(model, engine, [.failed(.networkUnavailable)])
        await settle(model, engine, [.trackChanged(makeTrack())])

        #expect(model.state.phase == .error(.networkUnavailable))
        #expect(model.state.currentTrack?.title == "Title")
    }

    @Test func startupStaysPendingUntilTheEngineResolvesIt() async {
        let engine = StubPlaybackEngine()
        let model = PlayerModel(engine: engine)
        #expect(model.state.startup == .pending)
        model.start()
        defer { model.stop() }
        await settle(model, engine, [.loading])
        #expect(model.state.startup == .pending)
        await settle(model, engine, [.startupResolved(.restored), .trackChanged(makeTrack()), .paused(positionMs: 1545)])
        #expect(model.state.startup == .resolved(.restored))
        #expect(model.state.phase == .paused)
        #expect(model.state.positionMs == 1545)
    }
}
