import Foundation
import Testing
@testable import BopifyPlayback
import BopifyDomain

@MainActor @Suite("Player volume")
struct PlayerVolumeTests {
    @Test func rapidVolumeKeepsOnlyLatest() async {
        let engine = StubPlaybackEngine()
        let model = PlayerModel(engine: engine)
        model.start()
        defer { model.stop() }
        engine.emit(.playing(positionMs: 0))
        await waitUntil { model.state.isActiveDevice }
        for index in 0..<100 { model.setVolume(Double(index) / 100) }
        await waitUntil { engine.recordedCommands.last == "setVolume:0.99" }
        #expect(engine.recordedCommands == ["setVolume:0.99"])
    }

    @Test func releaseFlushesBehindInFlightWithoutBlockingPause() async {
        let engine = ControlledVolumeEngine()
        let model = PlayerModel(engine: engine)
        model.start()
        defer { model.stop() }
        engine.stub.emit(.playing(positionMs: 0))
        engine.stub.emit(.volumeChanged(volume: 0.5))
        await waitUntil { model.state.volume == 0.5 && model.state.isActiveDevice }
        model.beginVolumeEditing()
        model.setVolume(0.1)
        await waitUntil { engine.stub.recordedCommands.contains("setVolume:0.1") }
        for index in 20...83 { model.setVolume(Double(index) / 100) }
        model.endVolumeEditing()
        model.togglePlayPause()
        await waitUntil { engine.stub.recordedCommands.contains("pause") }
        #expect(model.displayVolume == 0.83)
        #expect(model.state.volume == 0.5)
        await engine.resolve()
        await waitUntil { engine.stub.recordedCommands.contains("setVolume:0.83") }
        #expect(engine.stub.recordedCommands.filter { $0.hasPrefix("setVolume:") } == ["setVolume:0.1", "setVolume:0.83"])
        #expect(await engine.maxConcurrent == 1)
        await engine.resolve()
        engine.stub.emit(.volumeChanged(volume: 0.83))
        await waitUntil { model.state.volume == 0.83 }
        #expect(model.displayVolume == 0.83)
    }

    @Test func normalUpdatesWaitButFinalValueBypassesDelay() async {
        let clock = VolumeClock()
        let engine = StubPlaybackEngine()
        let model = PlayerModel(engine: engine, volumeNow: { clock.now }, volumeSleep: { try await clock.sleep($0) })
        model.start()
        defer { model.stop() }
        engine.emit(.playing(positionMs: 0))
        await waitUntil { model.state.isActiveDevice }
        model.beginVolumeEditing()
        model.setVolume(0.1)
        await waitUntil { engine.recordedCommands.count == 1 }
        model.setVolume(0.2)
        await waitUntil { clock.pendingCount == 1 }
        clock.advance(by: 0.149)
        #expect(engine.recordedCommands == ["setVolume:0.1"])
        model.setVolume(0.3)
        clock.advance(by: 0.001)
        await waitUntil { engine.recordedCommands.count == 2 }
        #expect(engine.recordedCommands.last == "setVolume:0.3")
        model.setVolume(0.4)
        await waitUntil { clock.pendingCount == 1 }
        model.endVolumeEditing()
        await waitUntil { engine.recordedCommands.count == 3 }
        #expect(engine.recordedCommands.last == "setVolume:0.4")
        #expect(clock.now == 0.15)
    }

    @Test func invalidAndDuplicateValuesDoNotDispatch() async {
        let engine = StubPlaybackEngine()
        let model = PlayerModel(engine: engine)
        model.start()
        defer { model.stop() }
        engine.emit(.playing(positionMs: 0))
        await waitUntil { model.state.isActiveDevice }
        model.setVolume(.nan)
        model.setVolume(.infinity)
        model.setVolume(2)
        model.setVolume(1)
        model.endVolumeEditing()
        model.togglePlayPause()
        await waitUntil { engine.recordedCommands.contains("pause") }
        #expect(engine.recordedCommands.filter { $0.hasPrefix("setVolume:") }.isEmpty)
        model.setVolume(-1)
        model.setVolume(0)
        model.endVolumeEditing()
        await waitUntil { engine.recordedCommands.contains("setVolume:0.0") }
        #expect(engine.recordedCommands.filter { $0.hasPrefix("setVolume:") } == ["setVolume:0.0"])
    }

    @Test func muteSupersedesPendingSliderValue() async {
        let engine = ControlledVolumeEngine()
        let model = PlayerModel(engine: engine)
        model.start()
        defer { model.stop() }
        engine.stub.emit(.playing(positionMs: 0))
        engine.stub.emit(.volumeChanged(volume: 0.6))
        await waitUntil { model.state.volume == 0.6 }
        model.beginVolumeEditing()
        model.setVolume(0.2)
        await waitUntil { engine.stub.recordedCommands.count == 1 }
        model.setVolume(0.8)
        model.toggleMute()
        await engine.resolve()
        await waitUntil { engine.stub.recordedCommands.count == 2 }
        #expect(engine.stub.recordedCommands == ["setVolume:0.2", "setVolume:0.0"])
        await engine.resolve()
    }

    @Test(arguments: [false, true])
    func obsoleteCompletionCannotResendAfterReactivation(stop: Bool) async {
        let engine = ControlledVolumeEngine()
        let model = PlayerModel(engine: engine)
        model.start()
        defer { model.stop() }
        engine.stub.emit(.playing(positionMs: 0))
        await waitUntil { model.state.isActiveDevice }
        model.setVolume(0.1)
        await waitUntil { engine.stub.recordedCommands.count == 1 }
        model.setVolume(0.9)
        model.endVolumeEditing()
        if stop {
            model.stop()
            model.start()
        } else {
            engine.stub.emit(.activeDeviceChanged(isActive: false))
            await waitUntil { !model.state.isActiveDevice }
            engine.stub.emit(.playing(positionMs: 0))
            await waitUntil { model.state.isActiveDevice }
        }
        model.beginVolumeEditing()
        model.setVolume(0.4)
        model.endVolumeEditing()
        await engine.resolve(error: .networkUnavailable)
        await waitUntil { engine.stub.recordedCommands.count == 2 }
        #expect(engine.stub.recordedCommands == ["setVolume:0.1", "setVolume:0.4"])
        #expect(await engine.maxConcurrent == 1)
        #expect(model.commandNotice == nil)
        #expect(model.displayVolume == 0.4)
        await engine.resolve()
    }

    @Test func failureReturnsDraftToConfirmedVolume() async {
        let engine = ControlledVolumeEngine()
        let model = PlayerModel(engine: engine)
        model.start()
        defer { model.stop() }
        engine.stub.emit(.playing(positionMs: 0))
        engine.stub.emit(.volumeChanged(volume: 0.65))
        await waitUntil { model.state.volume == 0.65 }
        model.beginVolumeEditing()
        model.setVolume(0.3)
        model.endVolumeEditing()
        await waitUntil { engine.stub.recordedCommands.count == 1 }
        await engine.resolve(error: .networkUnavailable)
        await waitUntil { model.commandNotice != nil }
        #expect(model.displayVolume == 0.65)
        #expect(model.state.volume == 0.65)
        engine.stub.emit(.volumeChanged(volume: 0.8))
        await waitUntil { model.displayVolume == 0.8 }
    }

    @Test func releaseCommitsDraftAfterAnExternalVolumeChange() async {
        let engine = StubPlaybackEngine()
        let model = PlayerModel(engine: engine)
        model.start()
        defer { model.stop() }
        engine.emit(.playing(positionMs: 0))
        await waitUntil { model.state.isActiveDevice }
        model.beginVolumeEditing()
        model.setVolume(0.3)
        await waitUntil { engine.recordedCommands == ["setVolume:0.3"] }
        engine.emit(.volumeChanged(volume: 0.8))
        await waitUntil { model.state.volume == 0.8 }
        #expect(model.displayVolume == 0.3)
        model.endVolumeEditing()
        await waitUntil { engine.recordedCommands.count == 2 }
        #expect(engine.recordedCommands == ["setVolume:0.3", "setVolume:0.3"])
        engine.emit(.volumeChanged(volume: 0.3))
        await waitUntil { model.state.volume == 0.3 }
        engine.emit(.volumeChanged(volume: 0.9))
        await waitUntil { model.displayVolume == 0.9 }
    }

    @Test func newEditSupersedesOldFinalAndCancelDropsUnsentWork() async {
        let engine = ControlledVolumeEngine()
        let model = PlayerModel(engine: engine)
        model.start()
        defer { model.stop() }
        engine.stub.emit(.playing(positionMs: 0))
        await waitUntil { model.state.isActiveDevice }
        model.setVolume(0.1)
        await waitUntil { engine.stub.recordedCommands.count == 1 }
        model.setVolume(0.8)
        model.endVolumeEditing()
        model.beginVolumeEditing()
        model.setVolume(0.4)
        model.endVolumeEditing()
        await engine.resolve()
        await waitUntil { engine.stub.recordedCommands.count == 2 }
        #expect(engine.stub.recordedCommands.last == "setVolume:0.4")
        model.beginVolumeEditing()
        model.setVolume(0.7)
        model.cancelVolumeEditing()
        await engine.resolve()
        model.togglePlayPause()
        await waitUntil { engine.stub.recordedCommands.contains("pause") }
        #expect(engine.stub.recordedCommands.filter { $0.hasPrefix("setVolume:") } == ["setVolume:0.1", "setVolume:0.4"])
        #expect(model.displayVolume == model.state.volume)
    }
}

private actor ControlledVolumeEngine: PlaybackEngine {
    nonisolated let stub = StubPlaybackEngine()
    nonisolated var events: AsyncStream<PlaybackEvent> { stub.events }
    private var completions: [CheckedContinuation<Void, Error>] = []
    private var concurrent = 0
    private(set) var maxConcurrent = 0
    func setVolume(_ value: Double) async throws {
        concurrent += 1
        maxConcurrent = max(maxConcurrent, concurrent)
        defer { concurrent -= 1 }
        try await stub.setVolume(value)
        try await withCheckedThrowingContinuation { completions.append($0) }
    }
    func resolve(error: PlayerError? = nil) {
        guard !completions.isEmpty else { Issue.record("No pending volume command"); return }
        let completion = completions.removeFirst()
        if let error { completion.resume(throwing: error) } else { completion.resume() }
    }
    func load(_ request: PlayRequest) async throws { try await stub.load(request) }
    func resume() async throws { try await stub.resume() }
    func playHere() async throws { try await stub.playHere() }
    func pause() async throws { try await stub.pause() }
    func next() async throws { try await stub.next() }
    func previous() async throws { try await stub.previous() }
    func seek(to milliseconds: Int64) async throws { try await stub.seek(to: milliseconds) }
    func selectQueueEntry(_ target: QueueTarget) async throws { try await stub.selectQueueEntry(target) }
    func setShuffle(_ enabled: Bool) async throws { try await stub.setShuffle(enabled) }
    func setRepeat(_ mode: RepeatMode) async throws { try await stub.setRepeat(mode) }
    func requestRadio(seed: SpotifyURI) async throws -> RadioMix { throw RadioFailure.unavailable }
    func requestLyrics(for track: SpotifyURI) async throws -> TrackLyrics { throw LyricFailure.unavailable }
}

@MainActor private final class VolumeClock {
    private(set) var now: TimeInterval = 0
    private var waits: [UUID: (TimeInterval, CheckedContinuation<Void, Error>)] = [:]
    var pendingCount: Int { waits.count }
    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        let parts = duration.components
        let deadline = now + Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { waits[id] = (deadline, $0) }
        } onCancel: {
            Task { @MainActor in self.waits.removeValue(forKey: id)?.1.resume(throwing: CancellationError()) }
        }
    }
    func advance(by seconds: TimeInterval) {
        now += seconds
        for (id, wait) in waits where wait.0 <= now {
            waits.removeValue(forKey: id)?.1.resume()
        }
    }
}

@MainActor private func waitUntil(_ predicate: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !predicate() {
        guard ContinuousClock.now < deadline else {
            Issue.record("Timed out waiting for volume state", sourceLocation: sourceLocation)
            return
        }
        await Task.yield()
    }
}
