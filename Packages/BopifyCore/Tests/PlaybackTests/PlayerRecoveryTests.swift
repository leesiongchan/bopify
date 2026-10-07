import Testing
import Foundation
import BopifyDomain
@testable import BopifyPlayback

@MainActor
@Suite("PlayerRecovery")
struct PlayerRecoveryTests {
    func settle() async { for _ in 0..<100 { await Task.yield() } }
    func track(_ title: String = "Old") -> Track { Track(uri: SpotifyURI("spotify:track:6rqhFgbbKwnb9MLmUQDhG6")!, title: title, artists: [], albumTitle: nil, artwork: nil, durationMs: 200_000) }
    var identity: PlaybackIdentity { PlaybackIdentity(trackURI: track().uri, trackUID: "second", contextURI: "spotify:playlist:p") }
    func queue() -> PlaybackQueue { PlaybackQueue(generation: 1, previous: [], current: nil, next: [QueueEntry(id: "next", uri: track().uri, target: QueueTarget(generation: 1, rawNextIndex: 0), track: nil, metadataFailed: false)]) }

    @Test func replacementKeepsMetadataAndFrozenPositionUntilReady() async {
        let old = RecoveryStubEngine(), replacement = RecoveryStubEngine()
        let model = PlayerModel(engine: old)
        let object = ObjectIdentifier(model)
        model.start()
        old.emit(.trackChanged(track())); old.emit(.playing(positionMs: 3200)); old.emit(.recoveryIdentity(identity))
        await settle()
        model.detachEngine()
        let frozen = model.displayPositionMs(at: .now)
        model.attachEngine(replacement, epoch: 1)
        replacement.emit(.trackChanged(track("New"))); replacement.emit(.paused(positionMs: 1000)); replacement.emit(.volumeChanged(volume: 0))
        old.emit(.trackChanged(track("Late old")))
        await settle()
        #expect(model.state.currentTrack?.title == "Old")
        #expect(model.displayPositionMs(at: .now.addingTimeInterval(20)) == frozen)
        #expect(!model.isEngineReady)
        model.togglePlayPause(); model.setVolume(0.5)
        await settle()
        #expect(replacement.recordedCommands.isEmpty)
        replacement.emit(.connectionReady(.local(identity)))
        await settle()
        #expect(model.isEngineReady)
        #expect(model.state.currentTrack?.title == "New")
        #expect(model.state.volume == 0)
        #expect(ObjectIdentifier(model) == object)
        model.stop()
    }

    @Test func terminalLossAndStreamEndCoalesceAndPreserveLoadingIntent() async {
        let engine = RecoveryStubEngine()
        let model = PlayerModel(engine: engine)
        var snapshots: [PlaybackRecoverySnapshot] = []
        model.onSessionLost = { _, snapshot in snapshots.append(snapshot) }
        model.start()
        engine.emit(.trackChanged(track())); engine.emit(.playing(positionMs: 3200)); engine.emit(.recoveryIdentity(identity)); engine.emit(.loading)
        await settle()
        engine.emit(.sessionLost(.spircEnded)); engine.emit(.failed(.playbackSessionLost)); engine.finishEvents()
        await settle()
        #expect(snapshots.count == 1)
        #expect(snapshots.first?.shouldResume == true)
        #expect(snapshots.first?.identity?.trackUID == "second")
        #expect(!model.isEngineReady)
        model.stop()
    }

    @Test func streamEndReportsLossButIntentionalStopDoesNot() async {
        let engine = RecoveryStubEngine()
        let model = PlayerModel(engine: engine)
        var reasons: [SessionLossReason] = []
        model.onSessionLost = { reason, _ in reasons.append(reason) }
        model.start(); engine.finishEvents(); await settle()
        #expect(reasons == [.eventStreamEnded])
        let next = RecoveryStubEngine()
        model.attachEngine(next, epoch: 2); model.stop(); next.finishEvents(); await settle()
        #expect(reasons.count == 1)
    }

    @Test func oldQueueTargetsAreRejectedEvenWhenGenerationRepeats() async {
        let first = RecoveryStubEngine(), second = RecoveryStubEngine()
        let model = PlayerModel(engine: first)
        model.start(); first.emit(.queueChanged(queue())); first.emit(.paused(positionMs: 0)); await settle()
        let target = model.state.queue!.next[0].target!
        model.attachEngine(second, epoch: 7)
        second.emit(.queueChanged(queue())); second.emit(.paused(positionMs: 0)); second.emit(.connectionReady(.local(identity))); await settle()
        model.selectQueueEntry(target); await settle()
        #expect(second.recordedCommands.isEmpty)
        #expect(model.state.queue?.next[0].target?.engineEpoch == 7)
        model.selectQueueEntry(model.state.queue!.next[0].target!); await settle()
        #expect(second.recordedCommands == ["selectQueue"])
        model.stop()
    }

    @Test func endedPausedAndRemoteNeverAuthorizeResume() async {
        for event in [PlaybackEvent.endOfTrack, .paused(positionMs: 3200), .activeDeviceChanged(isActive: false)] {
            let engine = RecoveryStubEngine(), model = PlayerModel(engine: RecoveryStubEngine())
            model.attachEngine(engine, epoch: 1)
            engine.emit(.trackChanged(track())); engine.emit(.playing(positionMs: 3200)); engine.emit(.recoveryIdentity(identity)); engine.emit(.connectionReady(.local(identity))); engine.emit(event)
            await settle()
            #expect(!model.captureRecoverySnapshot(at: .now).shouldResume)
            model.stop()
        }
    }

    @Test func sessionLossFromCommandStartsRecoveryOnce() async {
        let engine = RecoveryStubEngine()
        engine.commandError = .playbackSessionLost
        let model = PlayerModel(engine: engine)
        var count = 0
        model.onSessionLost = { _, _ in count += 1 }
        model.start(); engine.emit(.paused(positionMs: 0)); await settle()
        model.togglePlayPause(); await settle()
        engine.emit(.sessionLost(.commandFailed)); await settle()
        #expect(count == 1)
        #expect(!model.isEngineReady)
        model.stop()
    }
}
