import Testing
import Foundation
@testable import BopifyPlayback
import BopifyDomain

@MainActor
@Suite("PlayerModel")
struct PlayerModelTests {
    @Test func eventSynchronizationWaitsForSlowDelivery() async {
        let engine = StubPlaybackEngine(eventDelay: .milliseconds(80))
        let model = PlayerModel(engine: engine)
        model.start()
        defer { model.stop() }
        await settle(model, engine, [.trackChanged(makeTrack()), .playing(positionMs: 1000), .loading])
        #expect(model.state.currentTrack?.title == "Title")
        #expect(model.state.phase == .loading)
        #expect(await engine.consumedEvents() == 3)
    }

    @Test(arguments: ["unchanged", "queueOnly", "sameURITrack"])
    func queuedSeekCannotOutliveItsSongOccurrence(change: String) async throws {
        let engine = RecoveryStubEngine()
        let model = PlayerModel(engine: engine)
        model.start()
        let (release, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish(); model.stop() }
        let track = makeTrack()
        let entry = QueueEntry(id: "one", uri: track.uri, target: nil, track: track, metadataFailed: false)
        engine.emit(.trackChanged(track))
        engine.emit(.queueChanged(PlaybackQueue(generation: 1, previous: [], current: entry, next: [])))
        engine.emit(.paused(positionMs: 1000))
        for _ in 0..<10_000 { if model.state.phase == .paused { break }; await Task.yield() }
        try #require(model.state.phase == .paused)
        engine.commandGate = { for await _ in release { break } }
        model.next()
        for _ in 0..<10_000 { if engine.recordedCommands == ["next"] { break }; await Task.yield() }
        try #require(engine.recordedCommands == ["next"])
        model.seek(to: 2000)
        model.previous()
        let revision = model.playbackRevision
        if change == "queueOnly" {
            let replacement = QueueEntry(id: "two", uri: track.uri, target: nil, track: track, metadataFailed: false)
            engine.emit(.queueChanged(PlaybackQueue(generation: 1, previous: [], current: replacement, next: [])))
            for _ in 0..<10_000 { if model.state.queue?.current?.id == "two" { break }; await Task.yield() }
            try #require(model.state.queue?.current?.id == "two")
        } else if change == "sameURITrack" {
            engine.emit(.trackChanged(track))
            for _ in 0..<10_000 { if model.playbackRevision != revision { break }; await Task.yield() }
            try #require(model.playbackRevision != revision)
        }
        continuation.finish()
        for _ in 0..<10_000 { if engine.recordedCommands.last == "previous" { break }; await Task.yield() }
        #expect(engine.recordedCommands == (change == "unchanged" ? ["next", "seek", "previous"] : ["next", "previous"]))
    }

    @Test func sameURITrackChangedAdvancesPlaybackRevisionWithoutLoading() async {
        let engine = StubPlaybackEngine()
        let model = PlayerModel(engine: engine)
        model.start()
        defer { model.stop() }
        let track = makeTrack()
        let entry = QueueEntry(id: "same-entry", uri: track.uri, target: nil, track: track, metadataFailed: false)
        await settle(model, engine, [.queueChanged(PlaybackQueue(generation: 1, previous: [], current: entry, next: [])),
            .trackChanged(track), .playing(positionMs: 0), .endOfTrack, .trackChanged(track)])
        #expect(model.playbackRevision == 2)
        #expect(model.seekRevision == 0)
        #expect(model.state.queue?.current?.id == "same-entry")
    }

    @Test func onlyConfirmedSeekAdvancesSeekRevision() async {
        let engine = StubPlaybackEngine()
        let model = PlayerModel(engine: engine)
        model.start()
        defer { model.stop() }
        await settle(model, engine, [.trackChanged(makeTrack()), .playing(positionMs: 0),
            .positionCorrection(positionMs: 5000), .paused(positionMs: 5000), .playing(positionMs: 5000)])
        #expect(model.playbackRevision == 1)
        #expect(model.seekRevision == 0)
        await settle(model, engine, [.seeked(positionMs: 30_000)])
        #expect(model.seekRevision == 1)
        #expect(model.playbackRevision == 1)
        #expect(model.displayPositionMs(at: model.positionUpdatedAt.addingTimeInterval(1)) == 31_000)
    }

    @Test func metadataAndCommandsDoNotInventPlaythroughs() async throws {
        let engine = RecoveryStubEngine()
        let model = PlayerModel(engine: engine)
        model.start()
        defer { model.stop() }
        let track = makeTrack()
        let entry = QueueEntry(id: "entry", uri: track.uri, target: nil, track: nil, metadataFailed: false)
        engine.emit(.trackChanged(track))
        engine.emit(.queueChanged(PlaybackQueue(generation: 1, previous: [], current: entry, next: [])))
        engine.emit(.paused(positionMs: 1000))
        for _ in 0..<10_000 { if model.state.phase == .paused { break }; await Task.yield() }
        try #require(model.state.phase == .paused)
        engine.commandError = .unknown
        engine.emit(.queueMetadata(generation: 1, entryID: "entry", track: track))
        model.seek(to: 2000)
        for _ in 0..<10_000 { if model.commandNotice != nil { break }; await Task.yield() }
        try #require(model.commandNotice != nil)
        #expect(model.playbackRevision == 1)
        #expect(model.seekRevision == 0)
        #expect(model.state.positionMs == 1000)
    }

    @Test func muteRestoresOnlyConfirmedSessionVolume() async {
        let engine = StubPlaybackEngine()
        let model = PlayerModel(engine: engine)
        model.start()
        defer { model.stop() }
        await settle(model, engine, [.playing(positionMs: 0), .volumeChanged(volume: 0.65)])
        model.toggleMute()
        await waitUntil { engine.recordedCommands.count == 1 }
        #expect(engine.recordedCommands == ["setVolume:0.0"])
        #expect(model.state.volume == 0.65)
        await settle(model, engine, [.volumeChanged(volume: 0)])
        model.toggleMute()
        await waitUntil { engine.recordedCommands.count == 2 }
        #expect(engine.recordedCommands.last == "setVolume:0.65")
        #expect(model.state.volume == 0)
        await settle(model, engine, [.volumeChanged(volume: 0.3), .volumeChanged(volume: 0)])
        model.toggleMute()
        await waitUntil { engine.recordedCommands.count == 3 }
        #expect(engine.recordedCommands.last == "setVolume:0.3")
        await settle(model, engine, [.activeDeviceChanged(isActive: false)])
        let count = engine.recordedCommands.count
        model.toggleMute()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(engine.recordedCommands.count == count)
    }

    @Test func unmuteWithoutHistoryUsesHalfVolumeAndStopClearsMemory() async {
        let engine = StubPlaybackEngine()
        let model = PlayerModel(engine: engine)
        model.start()
        await settle(model, engine, [.playing(positionMs: 0), .volumeChanged(volume: 0)])
        model.toggleMute()
        await waitUntil { engine.recordedCommands.count == 1 }
        #expect(engine.recordedCommands == ["setVolume:0.5"])
        await settle(model, engine, [.volumeChanged(volume: 0.9), .volumeChanged(volume: 0)])
        model.stop()
        model.start()
        model.toggleMute()
        await waitUntil { engine.recordedCommands.count == 2 }
        #expect(engine.recordedCommands.last == "setVolume:0.5")
        model.stop()
    }

    private func selectionQueue() -> PlaybackQueue {
        PlaybackQueue(generation: 10, previous: [], current: nil, next: (0..<2).map {
            QueueEntry(id: "duplicate-\($0)", uri: makeTrack().uri,
                       target: QueueTarget(generation: 10, rawNextIndex: UInt32($0)), track: nil, metadataFailed: false)
        })
    }

    @Test func queueSelectionWaitsForTheExactOccurrence() async {
        let engine = StubPlaybackEngine()
        let model = PlayerModel(engine: engine)
        model.start()
        defer { model.stop() }
        let queue = selectionQueue()
        let entry = queue.next[1]
        await settle(model, engine, [.playing(positionMs: 0), .queueChanged(queue)])
        model.selectQueueEntry(entry.target!)
        await settle(model, engine, [.trackChanged(makeTrack())])
        #expect(model.queueSelection == .pending(entryID: entry.id, target: entry.target!))
        let current = QueueEntry(id: entry.id, uri: entry.uri, target: nil, track: nil, metadataFailed: false)
        await settle(model, engine, [.queueChanged(PlaybackQueue(generation: 11, previous: [], current: current, next: []))])
        #expect(model.queueSelection == .confirmed(entryID: entry.id, target: entry.target!))
        model.stop()
        #expect(model.queueSelection == .idle)
        #expect(PlayerModel(engine: StubPlaybackEngine()).queueSelection == .idle)
    }

    @Test func anotherSameURIQueueOccurrenceFailsSelection() async {
        let engine = StubPlaybackEngine()
        let model = PlayerModel(engine: engine)
        model.start()
        defer { model.stop() }
        let queue = selectionQueue()
        await settle(model, engine, [.playing(positionMs: 0), .queueChanged(queue)])
        model.selectQueueEntry(queue.next[1].target!)
        await settle(model, engine, [.queueChanged(PlaybackQueue(generation: 11, previous: [], current: queue.next[0], next: []))])
        #expect(model.queueSelection == .failed)
        #expect(model.commandNotice != nil)
        model.selectQueueEntry(queue.next[1].target!)
        #expect(model.queueSelection == .failed)
    }

    @Test func rejectionCannotLaterBecomeSelectionSuccess() async {
        let engine = StubPlaybackEngine()
        let model = PlayerModel(engine: engine)
        model.start()
        defer { model.stop() }
        let queue = selectionQueue()
        await settle(model, engine, [.playing(positionMs: 0), .queueChanged(queue)])
        model.selectQueueEntry(queue.next[1].target!)
        await settle(model, engine, [.commandRejected("staleQueue")])
        #expect(model.queueSelection == .failed)
        await settle(model, engine, [.queueChanged(PlaybackQueue(generation: 11, previous: [], current: queue.next[1], next: []))])
        #expect(model.queueSelection == .failed)
    }

    @Test(arguments: [false, true])
    func queueOperationFailureDoesNotOverwriteAReplacement(_ replace: Bool) async {
        let engine = FailingSelectionEngine()
        let model = PlayerModel(engine: engine)
        model.start()
        defer { model.stop() }
        let queue = selectionQueue()
        await settle(model, engine.stub, [.playing(positionMs: 0), .queueChanged(queue)])
        model.selectQueueEntry(queue.next[0].target!)
        await waitUntil { await engine.rejection.started }
        if replace { model.selectQueueEntry(queue.next[1].target!) }
        await engine.rejection.release()
        if replace { await waitUntil { engine.stub.recordedCommands == ["selectQueue:10:1"] } }
        else { await waitUntil { model.queueSelection == .failed } }
        #expect(model.queueSelection == (replace ? .pending(entryID: queue.next[1].id, target: queue.next[1].target!) : .failed))
    }

    private func makeTrack() -> Track {
        Track(uri: SpotifyURI("spotify:track:abc")!, title: "Title",
              artists: [ArtistSummary(name: "Artist")], albumTitle: "Album",
              artwork: nil, durationMs: 240_000)
    }

    private func makeRemote(isPlaying: Bool = true, positionMs: Int64 = 1000) -> RemotePlayback {
        RemotePlayback(deviceName: "iPhone", trackURI: SpotifyURI("spotify:track:remote")!, track: nil,
                       isPlaying: isPlaying, positionMs: positionMs, durationMs: 200_000)
    }

    /// Emits events and waits for the model's consumer task to fold them in.
    private func settle(_ model: PlayerModel, _ engine: StubPlaybackEngine, _ events: [PlaybackEvent],
                        sourceLocation: SourceLocation = #_sourceLocation) async {
        for event in events { engine.emit(event) }
        let target = engine.emittedEvents
        await waitUntil(sourceLocation: sourceLocation) { await engine.consumedEvents() >= target }
    }

    private func waitUntil(sourceLocation: SourceLocation = #_sourceLocation,
                           _ condition: @MainActor () async -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await condition(), "Playback work did not finish before the deadline", sourceLocation: sourceLocation)
    }

    @Test func seekIsClampedWithoutPretendingItSucceeded() async {
        let engine = StubPlaybackEngine()
        let model = PlayerModel(engine: engine)
        model.start()
        defer { model.stop() }
        await settle(model, engine, [.trackChanged(makeTrack()), .paused(positionMs: 20_000)])
        model.seek(to: 900_000)
        await waitUntil { engine.recordedCommands == ["seek:240000"] }
        #expect(engine.recordedCommands == ["seek:240000"])
        #expect(model.state.positionMs == 20_000)
        #expect(model.state.phase == .paused)
    }
    @Test func modesWaitForEngineEventsAndRapidCommandsKeepOrder() async {
        let engine = StubPlaybackEngine(commandDelay: .milliseconds(80))
        let model = PlayerModel(engine: engine)
        model.start()
        defer { model.stop() }
        await settle(model, engine, [.trackChanged(makeTrack()), .playing(positionMs: 1000)])
        model.next()
        model.previous()
        model.next()
        model.setShuffle(true)
        model.setRepeat(.track)
        await waitUntil { engine.recordedCommands.count == 5 }
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
        await waitUntil { engine.recordedCommands.contains("pause") }

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
        await waitUntil { engine.recordedCommands.contains("load:spotify:playlist:xyz") }

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

    @Test(arguments: [PlaybackEvent.playing(positionMs: 0), .paused(positionMs: 0)])
    func theMirrorClearsWhenBopifyBecomesActiveAndStaysCleared(_ takeover: PlaybackEvent) async {
        let engine = StubPlaybackEngine()
        let model = PlayerModel(engine: engine)
        model.start()
        defer { model.stop() }
        await settle(model, engine, [.remotePlayback(makeRemote())])
        #expect(model.state.remote == makeRemote())
        #expect(model.state.mirror == makeRemote())
        await settle(model, engine, [.remotePlayback(nil)])
        #expect(model.state.remote == nil)
        // The stopped device's last state stays on the record, no longer playing.
        #expect(model.state.staleRemote == makeRemote(isPlaying: false))
        #expect(model.state.mirror == makeRemote(isPlaying: false))
        await settle(model, engine, [.remotePlayback(makeRemote()), takeover])
        #expect(model.state.remote == nil)
        #expect(model.state.mirror == nil)
        // A lookup that finishes after the takeover must not bring the mirror back.
        await settle(model, engine, [.remotePlayback(makeRemote())])
        #expect(model.state.mirror == nil)
        await settle(model, engine, [.activeDeviceChanged(isActive: false), .remotePlayback(makeRemote(isPlaying: false))])
        #expect(model.state.remote == makeRemote(isPlaying: false))
    }

    @Test func aFailureMovesALiveMirrorIntoTheStaleRecordAndStopsTheRing() async {
        let engine = StubPlaybackEngine()
        let model = PlayerModel(engine: engine)
        model.start()
        defer { model.stop() }
        await settle(model, engine, [.activeDeviceChanged(isActive: false), .remotePlayback(makeRemote())])
        await settle(model, engine, [.failed(.playbackSessionLost)])
        #expect(model.state.remote == nil)
        #expect(model.state.staleRemote == makeRemote(isPlaying: false))
        #expect(!model.isPositionAdvancing)
    }

    @Test func losingTheSessionWhilePlayingReleasesNowPlaying() async {
        let engine = StubPlaybackEngine()
        let model = PlayerModel(engine: engine)
        model.start()
        defer { model.stop() }
        await settle(model, engine, [.trackChanged(makeTrack()), .playing(positionMs: 0)])
        #expect(model.state.isActiveDevice)
        #expect(nowPlayingInfo(for: model.state, positionMs: 0) != nil)
        await settle(model, engine, [.failed(.playbackSessionLost)])
        #expect(!model.state.isActiveDevice)
        #expect(nowPlayingInfo(for: model.state, positionMs: 0) == nil)
    }

    @Test func becomingActiveAlwaysClearsTheMirrorEvenWithoutATakeoverEvent() async {
        let engine = StubPlaybackEngine()
        let model = PlayerModel(engine: engine)
        model.start()
        defer { model.stop() }
        await settle(model, engine, [.remotePlayback(makeRemote())])
        await settle(model, engine, [.activeDeviceChanged(isActive: true)])
        #expect(model.state.mirror == nil)
    }

    @Test func playWhileInactiveAsksTheEngineToPlayHereWithoutAssumingItWorked() async {
        let engine = StubPlaybackEngine()
        let model = PlayerModel(engine: engine)
        model.start()
        defer { model.stop() }
        model.togglePlayPause()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(engine.recordedCommands.isEmpty)  // nothing to take over yet
        await settle(model, engine, [.remotePlayback(makeRemote())])
        #expect(model.canPlayHere)
        model.togglePlayPause()
        await waitUntil { engine.recordedCommands == ["playHere"] }
        #expect(engine.recordedCommands == ["playHere"])
        // Only the engine's events may change the state.
        #expect(model.state.phase == .idle)
        #expect(model.state.remote == makeRemote())
        // At launch Bopify has no track, so the stopped device's stale mirror is what Play resumes.
        await settle(model, engine, [.remotePlayback(nil)])
        #expect(model.canPlayHere)
    }

    @Test func aStaleTrackCanBePlayedHereButNotAfterAFailure() async {
        let engine = StubPlaybackEngine()
        let model = PlayerModel(engine: engine)
        model.start()
        defer { model.stop() }
        await settle(model, engine, [.trackChanged(makeTrack()), .paused(positionMs: 0)])
        #expect(!model.canPlayHere)  // while active, Play is resume
        await settle(model, engine, [.activeDeviceChanged(isActive: false)])
        #expect(model.canPlayHere)
        model.playHere()
        await waitUntil { engine.recordedCommands == ["playHere"] }
        #expect(engine.recordedCommands == ["playHere"])
        await settle(model, engine, [.failed(.playbackSessionLost)])
        #expect(!model.canPlayHere)
    }

    @Test func theMirrorAdvancesFromItsReceiptTimeAndOwnsTheDisplayedDuration() async {
        let engine = StubPlaybackEngine()
        let model = PlayerModel(engine: engine)
        model.start()
        defer { model.stop() }
        await settle(model, engine, [.trackChanged(makeTrack()), .paused(positionMs: 4000),
                                     .activeDeviceChanged(isActive: false), .remotePlayback(makeRemote(positionMs: 1000))])
        let anchor = model.remoteUpdatedAt
        #expect(model.displayPositionMs(at: anchor.addingTimeInterval(2)) == 3000)
        #expect(model.displayPositionMs(at: anchor.addingTimeInterval(600)) == 200_000)
        #expect(model.displayPositionMs(at: anchor.addingTimeInterval(-2)) == 1000)
        #expect(model.displayDurationMs == 200_000)
        #expect(model.isPositionAdvancing)
        await settle(model, engine, [.remotePlayback(makeRemote(isPlaying: false, positionMs: 5000))])
        #expect(model.displayPositionMs(at: model.remoteUpdatedAt.addingTimeInterval(20)) == 5000)
        #expect(!model.isPositionAdvancing)
        await settle(model, engine, [.remotePlayback(nil)])
        // The stopped device's last state stays on the record, frozen.
        #expect(model.displayPositionMs(at: .now.addingTimeInterval(20)) == 5000)
        #expect(model.displayDurationMs == 200_000)
        #expect(!model.isPositionAdvancing)
        await settle(model, engine, [.paused(positionMs: 4000)])
        #expect(model.displayPositionMs(at: .now) == 4000)
        #expect(model.displayDurationMs == 240_000)
    }
}

private struct FailingSelectionEngine: PlaybackEngine {
    let stub = StubPlaybackEngine()
    let rejection = SelectionFailureGate()
    var events: AsyncStream<PlaybackEvent> { stub.events }
    func selectQueueEntry(_ target: QueueTarget) async throws {
        if target.rawNextIndex == 0 {
            await rejection.wait()
            throw NSError(domain: "Test rejection", code: 1)
        }
        try await stub.selectQueueEntry(target)
    }
    func load(_ request: PlayRequest) async throws { try await stub.load(request) }
    func resume() async throws { try await stub.resume() }
    func playHere() async throws { try await stub.playHere() }
    func pause() async throws { try await stub.pause() }
    func next() async throws { try await stub.next() }
    func previous() async throws { try await stub.previous() }
    func seek(to milliseconds: Int64) async throws { try await stub.seek(to: milliseconds) }
    func setVolume(_ value: Double) async throws { try await stub.setVolume(value) }
    func setShuffle(_ enabled: Bool) async throws { try await stub.setShuffle(enabled) }
    func setRepeat(_ mode: RepeatMode) async throws { try await stub.setRepeat(mode) }
    func requestRadio(seed: SpotifyURI) async throws -> RadioMix { throw RadioFailure.unavailable }
    func requestLyrics(for track: SpotifyURI) async throws -> TrackLyrics { throw LyricFailure.unavailable }
}

private actor SelectionFailureGate {
    private(set) var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}
