import Foundation
import Testing
import BopifyDomain
import BopifyPlayback

@MainActor @Suite("Live lyric session", .serialized, .timeLimit(.minutes(1)))
struct LiveLyricRibbonSessionTests {
    @Test func visibleLocalInputRequestsOnce() async throws {
        let f = LiveLyricFixture(); defer { f.stop() }
        try await f.load()
        #expect(f.gate.requests.count == 1)
        #expect(f.gate.requests[0].uri == liveLyricURI && f.gate.requests[0].epoch == f.player.engineEpoch)
        #expect(f.session.model.source?.attribution == "Fixture provider")
        #expect(f.session.model.projection?.current?.startMs == 1000)
        #expect(f.engine.commands.isEmpty)
    }

    @Test func artworkMetadataUpdatesPresentationWithoutRefetchingOrLeavingReading() async throws {
        let f = LiveLyricFixture(); defer { f.stop() }
        try await f.load()
        f.session.model.beginReading()
        let revision = f.session.model.scrollResetRevision
        let url = URL(string: "https://fixture.invalid/original-cover")!
        let track = Track(uri: liveLyricURI, title: "Window Seat", artists: [ArtistSummary(name: "Soft Weather")],
                          albumTitle: nil, artwork: Artwork(url: url), durationMs: 240_000)
        f.engine.emit(.queueMetadata(generation: 1, entryID: "one", track: track))
        try await liveLyricEventually { f.session.model.snapshot.artworkURL == url }
        #expect(f.gate.requests.count == 1)
        #expect(f.session.model.isReading && f.session.model.scrollResetRevision == revision)
        #expect(f.session.model.source?.attribution == "Fixture provider")
        #expect(f.engine.commands.isEmpty)
    }

    @Test(arguments: ["hidden", "notReady", "remote", "unsupported", "loading", "mismatch", "noTrack"])
    func ineligibleInputsNeverRequest(kind: String) async throws {
        let f = LiveLyricFixture(); defer { f.stop() }
        if kind != "noTrack" { try await f.ready() }
        var expected = LyricIdleReason.noTrack
        switch kind {
        case "notReady": f.player.detachEngine(); expected = .connecting
        case "remote":
            f.engine.emit(.activeDeviceChanged(isActive: false))
            f.engine.emit(.remotePlayback(RemotePlayback(deviceName: "Fixture device", trackURI: liveLyricURI,
                track: liveLyricTrack(), isPlaying: true, positionMs: 1000, durationMs: 240_000)))
            try await liveLyricEventually { f.player.state.mirror != nil }; expected = .otherDevice
        case "unsupported":
            let episode = SpotifyURI("spotify:episode:11dFghVXANMlKmJXsNCbNl")!
            f.engine.emit(.trackChanged(liveLyricTrack(episode))); f.engine.emit(.queueChanged(liveLyricQueue(episode)))
            try await liveLyricEventually { f.player.state.currentTrack?.uri == episode }; expected = .unsupported
        case "loading": f.engine.emit(.loading); try await liveLyricEventually { f.player.state.phase == .loading }; expected = .loadingTrack
        case "mismatch":
            f.engine.emit(.queueChanged(liveLyricQueue(otherLiveLyricURI)))
            try await liveLyricEventually { f.player.state.queue?.current?.uri == otherLiveLyricURI }; expected = .loadingTrack
        default: break
        }
        if kind != "hidden" {
            f.session.show()
            #expect(f.session.model.content == .idle(expected))
            #expect(f.session.model.projection == nil && f.session.model.source == nil)
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(f.gate.requests.isEmpty)
    }

    @Test(arguments: [true, false])
    func queueAndMetadataArrivalOrderCannotMislabelLyrics(queueFirst: Bool) async throws {
        let f = LiveLyricFixture(); defer { f.stop() }
        try await f.load()
        f.session.model.beginReading()
        let first: PlaybackEvent = queueFirst ? .queueChanged(liveLyricQueue(otherLiveLyricURI, id: "two")) : .trackChanged(liveLyricTrack(otherLiveLyricURI))
        let second: PlaybackEvent = queueFirst ? .trackChanged(liveLyricTrack(otherLiveLyricURI)) : .queueChanged(liveLyricQueue(otherLiveLyricURI, id: "two"))
        f.engine.emit(first)
        try await liveLyricEventually { f.session.model.content == .idle(.loadingTrack) }
        #expect(!f.session.model.isReading && f.session.model.source == nil)
        f.engine.emit(second)
        try await liveLyricEventually { f.gate.requests.count == 2 }
        f.gate.succeed(1, with: liveLyrics(otherLiveLyricURI))
        try await liveLyricEventually { f.session.model.source != nil }
        #expect(f.session.model.snapshot.recordingID == otherLiveLyricURI.rawValue)
    }

    @Test(arguments: [true, false], [true, false])
    func consecutiveSameRecordingEntriesReplaceReading(queueFirst: Bool, completeIntermediate: Bool) async throws {
        let f = LiveLyricFixture(); defer { f.stop() }
        try await f.load()
        f.session.model.beginReading()
        #expect(f.session.model.isReading)
        let original = f.session.model.snapshot.occurrenceID
        let queue = PlaybackEvent.queueChanged(liveLyricQueue(id: "two"))
        let track = PlaybackEvent.trackChanged(liveLyricTrack())
        f.engine.emit(queueFirst ? queue : track)
        f.engine.emit(.paused(positionMs: 1000))
        try await liveLyricEventually { f.gate.requests.count == 2 }
        let intermediate = f.session.model.snapshot.occurrenceID
        #expect(intermediate != original)
        #expect(!f.session.model.isReading && f.session.model.source == nil)
        if completeIntermediate {
            f.gate.succeed(1, with: liveLyrics(displayName: "Intermediate provider"))
            try await liveLyricEventually { f.session.model.source?.attribution == "Intermediate provider" }
            f.session.model.beginReading()
            #expect(f.session.model.isReading)
        }

        f.engine.emit(queueFirst ? track : queue)
        f.engine.emit(.paused(positionMs: 1000))
        try await liveLyricEventually { f.gate.requests.count == 3 }
        let finalOccurrence = f.session.model.snapshot.occurrenceID
        #expect(finalOccurrence != intermediate && finalOccurrence != original)
        #expect(!f.session.model.isReading && f.session.model.source == nil)
        f.gate.succeed(2, with: liveLyrics(displayName: "Current provider"))
        try await liveLyricEventually { f.session.model.source?.attribution == "Current provider" }
        if !completeIntermediate {
            f.gate.succeed(1, with: liveLyrics(displayName: "Stale provider"))
            for _ in 0..<30 { await Task.yield() }
        }
        #expect(f.session.model.source?.attribution == "Current provider")
        #expect(f.session.model.snapshot.occurrenceID == finalOccurrence)
        #expect(f.session.model.snapshot.recordingID == liveLyricURI.rawValue)
        #expect(f.session.model.projection?.current?.startMs == 1000)
        #expect(f.engine.commands.isEmpty)
    }

    @Test func sameURIRepeatWithoutLoadingReplacesHeldPassage() async throws {
        let f = LiveLyricFixture(); defer { f.stop() }
        try await f.load()
        let occurrence = f.session.model.snapshot.occurrenceID
        f.session.model.beginReading()
        f.engine.emit(.endOfTrack)
        try await liveLyricEventually { f.player.state.phase == .ended }
        #expect(f.session.model.isReading)
        f.engine.emit(.trackChanged(liveLyricTrack())); f.engine.emit(.playing(positionMs: 0))
        try await liveLyricEventually { f.gate.requests.count == 2 }
        #expect(!f.session.model.isReading && f.session.model.source == nil)
        #expect(f.session.model.snapshot.occurrenceID != occurrence)
        f.gate.succeed(1, with: liveLyrics())
        try await liveLyricEventually { f.session.model.source != nil }
    }

    @Test func lateOldCompletionCannotEraseNewRequest() async throws {
        let f = LiveLyricFixture(); defer { f.stop() }
        try await f.ready(); f.session.show()
        try await liveLyricEventually { f.gate.requests.count == 1 }
        f.engine.emit(.queueChanged(liveLyricQueue(otherLiveLyricURI, id: "two")))
        f.engine.emit(.trackChanged(liveLyricTrack(otherLiveLyricURI)))
        try await liveLyricEventually { f.gate.requests.count == 2 }
        f.gate.succeed(0, with: liveLyrics())
        for _ in 0..<30 { await Task.yield() }
        #expect(f.session.model.source == nil)
        f.session.hide()
        try await liveLyricEventually { f.gate.cancelled.contains(1) }
        f.gate.succeed(1, with: liveLyrics(otherLiveLyricURI))
        for _ in 0..<30 { await Task.yield() }
        #expect(!f.session.isVisible && f.session.model.source == nil)
    }

    @Test(arguments: ["hide", "epoch"])
    func hideReopenAndEpochReplacementRejectOldResults(path: String) async throws {
        let f = LiveLyricFixture(); defer { f.stop() }
        try await f.ready(); f.session.show()
        try await liveLyricEventually { f.gate.requests.count == 1 }
        let revision = f.player.playbackRevision
        if path == "hide" { f.session.hide(); f.session.show() }
        else {
            let replacement = LiveLyricTestEngine()
            f.player.attachEngine(replacement, epoch: 2)
            f.player.setConnectionReady(.local(PlaybackIdentity(trackURI: liveLyricURI)))
            replacement.emit(.trackChanged(liveLyricTrack()))
            replacement.emit(.queueChanged(liveLyricQueue()))
            replacement.emit(.paused(positionMs: 1000))
        }
        try await liveLyricEventually {
            f.gate.requests.count >= 2 && (path == "hide" ||
                (f.player.playbackRevision > revision && f.session.model.snapshot.sessionID == "2" &&
                 f.session.model.snapshot.occurrenceID == "\(f.player.playbackRevision):one"))
        }
        // The replacement may briefly expose retained metadata before its confirmed track event.
        for _ in 0..<20 { await Task.yield() }
        let id = f.gate.requests.last!.id
        f.gate.succeed(id, with: liveLyrics(displayName: "Fresh provider"))
        try await liveLyricEventually { f.session.model.source?.attribution == "Fresh provider" }
        f.gate.succeed(0, with: liveLyrics(displayName: "Old provider"))
        for _ in 0..<30 { await Task.yield() }
        #expect(f.session.model.source?.attribution == "Fresh provider")
    }

    @Test(arguments: ["noLyrics", "network", "unavailable", "malformed"])
    func serviceFailuresDoNotRecoverPlayback(reason: String) async throws {
        let f = LiveLyricFixture(); defer { f.stop() }
        try await f.ready(); f.session.show()
        try await liveLyricEventually { f.gate.requests.count == 1 }
        if reason == "malformed" {
            f.gate.succeed(0, with: presentationLyrics(lines: [TrackLyricLine(text: "Words", startTimeMs: nil)]))
        } else { f.gate.fail(0, with: LyricFailure(rawValue: reason)!) }
        let expected = reason == "noLyrics" ? LyricContent.noMatch : .failure
        try await liveLyricEventually { f.session.model.content == expected }
        #expect(f.player.isEngineReady && f.engine.commands.isEmpty)
        #expect(f.session.model.source == nil)
    }

    @Test func pauseAndCorrectionsKeepHoldButSeekClearsIt() async throws {
        let f = LiveLyricFixture(); defer { f.stop() }
        try await f.load()
        f.session.model.beginReading()
        let scroll = f.session.model.scrollResetRevision
        f.engine.emit(.playing(positionMs: 1000)); f.engine.emit(.positionCorrection(positionMs: 3000))
        f.engine.emit(.paused(positionMs: 3000))
        try await liveLyricEventually { f.session.model.snapshot.positionMs == 3000 }
        #expect(f.session.model.isReading && f.session.model.scrollResetRevision == scroll)
        f.engine.emit(.seeked(positionMs: 2000))
        try await liveLyricEventually { !f.session.model.isReading }
        #expect(f.session.model.projection?.current?.startMs == 2000)
        #expect(f.gate.requests.count == 1 && f.engine.commands.isEmpty)
    }

    @Test func loadingSeekRestartClearsHold() async throws {
        let f = LiveLyricFixture(); defer { f.stop() }
        try await f.load(); f.session.model.beginReading()
        f.engine.emit(.loading)
        try await liveLyricEventually { f.session.model.content == .idle(.loadingTrack) }
        #expect(!f.session.model.isReading && f.session.model.source == nil)
        f.engine.emit(.trackChanged(liveLyricTrack())); f.engine.emit(.paused(positionMs: 2000))
        try await liveLyricEventually { f.gate.requests.count == 2 }
        #expect(f.player.seekRevision == 0)
    }

    @Test func visibleClockUsesThePlayerPosition() async throws {
        let f = LiveLyricFixture(); defer { f.stop() }
        try await f.load()
        f.engine.emit(.playing(positionMs: 1000))
        try await liveLyricEventually { f.clock.pendingDelays == [.milliseconds(100)] }
        f.clock.now = .now.addingTimeInterval(1.5)
        f.clock.advance(by: .milliseconds(100))
        try await liveLyricEventually { f.session.model.snapshot.positionMs == f.player.displayPositionMs(at: f.clock.now) }
        #expect(f.session.model.projection?.current?.startMs == 2000)
        f.engine.emit(.paused(positionMs: 20_000))
        try await liveLyricEventually { f.clock.pendingDelays.isEmpty && f.session.model.snapshot.positionMs == 20_000 }
        f.clock.advance(by: .seconds(60))
        #expect(f.session.model.snapshot.positionMs == 20_000)
    }

    @Test func hiddenStoppedAndReplacedClocksRejectLateWake() async throws {
        let f = LiveLyricFixture(); defer { f.stop() }
        try await f.load()
        f.engine.emit(.playing(positionMs: 1000))
        try await liveLyricEventually { !f.clock.pendingDelays.isEmpty }
        f.session.hide()
        try await liveLyricEventually { f.clock.pendingDelays.isEmpty }
        let position = f.session.model.snapshot.positionMs
        f.clock.advance(by: .seconds(10))
        #expect(f.session.model.snapshot.positionMs == position && f.session.model.projection == nil)
        f.session.show()
        try await liveLyricEventually { !f.clock.pendingDelays.isEmpty }
        f.session.shutdown()
        try await liveLyricEventually { f.clock.pendingDelays.isEmpty }
        f.clock.advance(by: .seconds(10))
        #expect(!f.session.isVisible)
    }

    @Test func heldEndAndFocusPreserveReading() async throws {
        let f = LiveLyricFixture(); defer { f.stop() }
        try await f.load(); f.session.model.beginReading()
        let scroll = f.session.model.scrollResetRevision
        f.session.show(); f.session.focusForReading()
        #expect(f.session.model.isReading && f.session.model.scrollResetRevision == scroll)
        #expect(f.gate.requests.count == 1 && f.engine.commands.isEmpty)
        f.engine.emit(.endOfTrack)
        try await liveLyricEventually { f.session.model.snapshot.positionMs == 240_000 && !f.session.model.snapshot.isPlaying }
        #expect(f.session.model.isReading)
        f.session.model.backToLive()
        #expect(f.session.model.projection?.interval == .ended)
    }
}

@MainActor private final class LiveLyricFixture {
    let engine = LiveLyricTestEngine()
    let gate = LiveLyricRequestGate()
    let clock = LiveLyricTestClock()
    let player: PlayerModel
    let session: LiveLyricRibbonSession
    private let suite = "live-lyrics-test-" + UUID().uuidString
    init() {
        player = PlayerModel(engine: engine)
        let gate = gate, clock = clock
        session = LiveLyricRibbonSession(player: player, requestLyrics: { try await gate.request(for: $0, epoch: $1) },
            defaults: UserDefaults(suiteName: suite)!, now: { clock.now }, sleep: { try await clock.sleep(for: $0) })
        player.start()
    }
    func ready() async throws {
        engine.emit(.trackChanged(liveLyricTrack())); engine.emit(.queueChanged(liveLyricQueue()))
        engine.emit(.paused(positionMs: 1000))
        try await liveLyricEventually { self.player.state.phase == .paused && self.player.state.currentTrack?.uri == liveLyricURI }
    }
    func load() async throws {
        try await ready(); session.show()
        try await liveLyricEventually { self.gate.requests.count == 1 }
        gate.succeed(0, with: liveLyrics())
        try await liveLyricEventually { self.session.model.source != nil }
    }
    func stop() { session.shutdown(); player.stop(); gate.finish(); UserDefaults.standard.removePersistentDomain(forName: suite) }
}
