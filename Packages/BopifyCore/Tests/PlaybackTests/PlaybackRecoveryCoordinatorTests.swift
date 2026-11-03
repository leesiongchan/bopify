import Testing
import Foundation
import BopifyDomain
@testable import BopifyPlayback

@MainActor @Suite("PlaybackRecoveryCoordinator")
struct PlaybackRecoveryCoordinatorTests {
    @Test(arguments: [0.0, 0.23])
    func coldLaunchPassesSavedVolumeBeforeCreatingEngine(volume: Double) async throws {
        let suite = "recovery-volume-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(volume, forKey: "player.volume")
        let gate = RecoveryFactoryGate()
        let recovery = PlaybackRecoveryCoordinator(player: PlayerModel(volumeDefaults: defaults),
            tokenProvider: { _ in "TOKEN_FAKE" },
            makeEngine: { _, options in try await gate.create(configuration: options) })
        recovery.start()
        await gate.waitForCreationCount(1)
        #expect(gate.configurations[0].startup == .coldLaunch)
        #expect(gate.configurations[0].snapshot == nil)
        #expect(gate.configurations[0].initialVolume == volume)
        gate.failNext(with: .networkUnavailable)
        await recovery.stop()
    }

    var identity: PlaybackIdentity { PlaybackIdentity(trackURI: SpotifyURI("spotify:track:6rqhFgbbKwnb9MLmUQDhG6")!) }
    func settle() async { for _ in 0..<100 { await Task.yield() } }
    func coordinator(_ gate: RecoveryFactoryGate, _ clock: RecoveryTestClock) -> PlaybackRecoveryCoordinator {
        PlaybackRecoveryCoordinator(player: PlayerModel(), tokenProvider: { _ in "TOKEN_FAKE" }, makeEngine: { _, options in try await gate.create(configuration: options) }, deviceID: "stable", now: { clock.now }, sleep: { try await clock.sleep(for: $0) }, randomUnit: { 1 })
    }
    @Test func retryDelaysFollowTheScheduleWithinJitterBounds() {
        #expect(recoveryRetryDelay(step: 0, jitterUnit: 1) == .zero)
        #expect(recoveryRetryDelay(step: 1, jitterUnit: 0) == .seconds(1))
        #expect(recoveryRetryDelay(step: 1, jitterUnit: 1) == .seconds(2))
        #expect(recoveryRetryDelay(step: 7, jitterUnit: 1) == .seconds(300))
        #expect(recoveryRetryDelay(step: Int.max, jitterUnit: 0) == .seconds(150))
        #expect(recoveryRetryDelay(step: -1, jitterUnit: 1) == .zero)
    }

    /// Connect failures climb the whole ladder and stay at its cap instead of giving up.
    @Test func connectFailuresClimbToTheFiveMinuteCap() async {
        let gate = RecoveryFactoryGate(), clock = RecoveryTestClock()
        let recovery = coordinator(gate, clock)
        recovery.start()
        for (attempt, seconds) in [2.0, 5, 15, 30, 60, 120, 300, 300].enumerated() {
            await gate.waitForCreationCount(attempt + 1)
            gate.failNext(with: .networkUnavailable); await settle()
            #expect(clock.pendingDelays.contains(.seconds(seconds)), "attempt \(attempt)")
            clock.advance(by: .seconds(seconds))
        }
        await gate.waitForCreationCount(9); gate.failNext(with: .networkUnavailable); await settle()
        await recovery.stop()
    }

    /// The old 60-second reset let a session that dropped every minute reconnect instantly forever.
    @Test func dropsEverySixtyOneSecondsStillEscalate() async {
        let gate = RecoveryFactoryGate(), clock = RecoveryTestClock()
        let recovery = coordinator(gate, clock)
        recovery.start(); await gate.waitForCreationCount(1)
        var engine = RecoveryStubEngine(); gate.succeedNext(with: engine); await settle()
        engine.emit(.connectionReady(.remote)); await settle()
        for (drop, seconds) in [0.0, 2, 5, 15, 30].enumerated() {
            clock.advance(by: .seconds(61)); await settle()
            engine.emit(.sessionLost(.spircEnded)); await settle()
            if seconds > 0 {
                #expect(clock.pendingDelays.contains(.seconds(seconds)), "drop \(drop)")
                #expect(gate.configurations.count == drop + 1)
                clock.advance(by: .seconds(seconds))
            }
            await gate.waitForCreationCount(drop + 2)
            engine = RecoveryStubEngine(); gate.succeedNext(with: engine); await settle()
            engine.emit(.connectionReady(.remote)); await settle()
        }
        await recovery.stop()
    }

    /// A loss recorded just before invalidate() must not make the next start() wait out the old ladder.
    @Test func startAfterInvalidateBeginsFromACleanLadder() async {
        let gate = RecoveryFactoryGate(), clock = RecoveryTestClock()
        let recovery = coordinator(gate, clock)
        recovery.start(); await gate.waitForCreationCount(1)
        var engine = RecoveryStubEngine(); gate.succeedNext(with: engine); await settle()
        engine.emit(.connectionReady(.remote)); await settle()
        for (drop, seconds) in [0.0, 2, 5].enumerated() {
            clock.advance(by: .seconds(61)); await settle()
            engine.emit(.sessionLost(.spircEnded)); await settle()
            if seconds > 0 { clock.advance(by: .seconds(seconds)) }
            await gate.waitForCreationCount(drop + 2)
            engine = RecoveryStubEngine(); gate.succeedNext(with: engine); await settle()
            engine.emit(.connectionReady(.remote)); await settle()
        }
        // Reported and invalidated without yielding, so the worker never consumes the pending wait.
        recovery.reportSessionLoss(.spircEnded, epoch: recovery.player.engineEpoch)
        recovery.invalidate()
        let creations = gate.configurations.count
        recovery.start(); await settle()
        #expect(gate.configurations.count == creations + 1)
        #expect(clock.pendingDelays.isEmpty)
        guard gate.configurations.count == creations + 1 else { return await recovery.stop() }
        gate.failNext(with: .networkUnavailable); await settle()
        #expect(clock.pendingDelays.contains(.seconds(2)), "connect-failure count restarts too")
        await recovery.stop()
    }

    @Test func dropsOlderThanTenMinutesStopCounting() async {
        let gate = RecoveryFactoryGate(), clock = RecoveryTestClock()
        let recovery = coordinator(gate, clock)
        recovery.start(); await gate.waitForCreationCount(1)
        var engine = RecoveryStubEngine(); gate.succeedNext(with: engine); await settle()
        engine.emit(.connectionReady(.remote)); await settle()
        engine.emit(.sessionLost(.spircEnded)); await gate.waitForCreationCount(2)
        engine = RecoveryStubEngine(); gate.succeedNext(with: engine); await settle(); engine.emit(.connectionReady(.remote)); await settle()
        engine.emit(.sessionLost(.spircEnded)); await settle()
        #expect(clock.pendingDelays.contains(.seconds(2)))
        clock.advance(by: .seconds(2)); await gate.waitForCreationCount(3)
        engine = RecoveryStubEngine(); gate.succeedNext(with: engine); await settle(); engine.emit(.connectionReady(.remote)); await settle()
        clock.advance(by: .seconds(601)); await settle()
        engine.emit(.sessionLost(.spircEnded)); await gate.waitForCreationCount(4)
        #expect(clock.pendingDelays.isEmpty)
        gate.failNext(with: .networkUnavailable); await settle()
        // Only the newest drop is inside the window, so the connect failure starts one rung up.
        #expect(clock.pendingDelays == [.seconds(2)])
        await recovery.stop()
    }

    /// Drops and connect failures share one ladder; a successful connection clears only the connect-failure count.
    @Test func dropsAndConnectFailuresShareTheLadderUntilReady() async {
        let gate = RecoveryFactoryGate(), clock = RecoveryTestClock()
        let recovery = coordinator(gate, clock)
        recovery.start(); await gate.waitForCreationCount(1)
        var engine = RecoveryStubEngine(); gate.succeedNext(with: engine); await settle()
        engine.emit(.connectionReady(.remote)); await settle()
        engine.emit(.sessionLost(.spircEnded)); await gate.waitForCreationCount(2)
        engine = RecoveryStubEngine(); gate.succeedNext(with: engine); await settle()
        engine.emit(.connectionReady(.remote)); await settle()
        engine.emit(.sessionLost(.spircEnded)); await settle()
        #expect(clock.pendingDelays == [.seconds(2)])
        clock.advance(by: .seconds(2)); await gate.waitForCreationCount(3)
        gate.failNext(with: .networkUnavailable); await settle()
        #expect(clock.pendingDelays == [.seconds(5)], "two drops plus a connect failure")
        clock.advance(by: .seconds(5)); await gate.waitForCreationCount(4)
        engine = RecoveryStubEngine(); gate.succeedNext(with: engine); await settle()
        engine.emit(.connectionReady(.remote)); await settle()
        engine.emit(.sessionLost(.spircEnded)); await settle()
        #expect(clock.pendingDelays == [.seconds(5)], "third drop; ready cleared the connect failure")
        clock.advance(by: .seconds(5)); await gate.waitForCreationCount(5)
        gate.failNext(with: .networkUnavailable); await settle()
        #expect(clock.pendingDelays == [.seconds(15)], "connect failure after the third drop")
        await recovery.stop()
    }

    @Test func onlyLongWaitsOfferAManualRetry() async {
        let gate = RecoveryFactoryGate(), clock = RecoveryTestClock()
        let recovery = coordinator(gate, clock)
        recovery.start()
        for (attempt, seconds) in [2.0, 5, 15].enumerated() {
            await gate.waitForCreationCount(attempt + 1); gate.failNext(with: .networkUnavailable); await settle()
            #expect(!recovery.offersManualRetry)
            clock.advance(by: .seconds(seconds))
        }
        await gate.waitForCreationCount(4); gate.failNext(with: .networkUnavailable); await settle()
        #expect(clock.pendingDelays.contains(.seconds(30)))
        #expect(recovery.offersManualRetry)
        recovery.retryNow(); await gate.waitForCreationCount(5)
        #expect(!recovery.offersManualRetry)
        gate.failNext(with: .networkUnavailable); await settle()
        await recovery.stop()
    }

    /// Wake and network changes must not loop on an account problem; an explicit Retry always tries again.
    @Test(arguments: [PlayerError.premiumRequired, .accountRestricted, .unknown]) func onlyAnExplicitRetryLeavesAFailure(_ error: PlayerError) async {
        let gate = RecoveryFactoryGate(), clock = RecoveryTestClock()
        let recovery = coordinator(gate, clock)
        recovery.start(); await gate.waitForCreationCount(1); gate.failNext(with: error); await settle()
        #expect(recovery.status == .failed(error))
        recovery.setNetworkAvailable(false); recovery.setNetworkAvailable(true); recovery.wake()
        clock.advance(by: .seconds(600)); await settle()
        #expect(gate.configurations.count == 1)
        recovery.retryNow(); await gate.waitForCreationCount(2)
        #expect(recovery.status == .connecting)
        gate.failNext(with: error); await settle()
        await recovery.stop()
    }
    @Test func hasBeenReadyDistinguishesFirstConnectionFromReconnection() async {
        let gate = RecoveryFactoryGate(), clock = RecoveryTestClock()
        let recovery = coordinator(gate, clock)
        recovery.start(); await gate.waitForCreationCount(1)
        gate.failNext(with: .networkUnavailable); await settle()
        #expect(recovery.status == .reconnecting)
        #expect(!recovery.hasBeenReady)
        clock.advance(by: .seconds(2)); await gate.waitForCreationCount(2)
        let engine = RecoveryStubEngine(); gate.succeedNext(with: engine); await settle()
        engine.emit(.connectionReady(.remote)); await settle()
        #expect(recovery.hasBeenReady)
        recovery.reportSessionLoss(.sessionDisconnected, epoch: recovery.player.engineEpoch)
        #expect(recovery.status == .reconnecting)
        #expect(recovery.hasBeenReady)
        await recovery.stop()
    }
    @Test func lossImmediatelyAfterReadinessCannotLeaveADeadEngineReady() async {
        let gate = RecoveryFactoryGate(), clock = RecoveryTestClock(), engine = RecoveryStubEngine()
        let recovery = coordinator(gate, clock)
        recovery.start(); await gate.waitForCreationCount(1); gate.succeedNext(with: engine); await settle()
        let ready = recovery.player.onConnectionReady
        recovery.player.onConnectionReady = { [weak recovery] outcome in
            ready?(outcome)
            if let recovery { recovery.reportSessionLoss(.spircEnded, epoch: recovery.player.engineEpoch) }
        }
        engine.emit(.connectionReady(.remote))
        await settle()
        #expect(recovery.status != .ready)
        if gate.configurations.count == 2 { gate.failNext(with: .networkUnavailable) }
        await recovery.stop()
    }

    @Test func stopDuringTokenLookupNeverCreates() async {
        let gate = RecoveryFactoryGate(), clock = RecoveryTestClock(), token = RecoverySuspension()
        let recovery = PlaybackRecoveryCoordinator(player: PlayerModel(), tokenProvider: { _ in await token.wait(); return "TOKEN_FAKE" }, makeEngine: { _, options in try await gate.create(configuration: options) }, sleep: { try await clock.sleep(for: $0) })
        recovery.start(); await token.entered()
        recovery.invalidate(); token.release(); await recovery.stop()
        #expect(gate.configurations.isEmpty)
        #expect(recovery.status == .stopped)
    }
    @Test func stopDuringReadinessAndShutdownWaitsForTeardown() async {
        let gate = RecoveryFactoryGate(), clock = RecoveryTestClock(), engine = RecoveryStubEngine(), shutdown = RecoverySuspension()
        engine.shutdownGate = { await shutdown.wait() }
        let recovery = coordinator(gate, clock)
        recovery.start(); await gate.waitForCreationCount(1); gate.succeedNext(with: engine); await settle()
        recovery.invalidate(); await shutdown.entered()
        #expect(recovery.currentEngine == nil)
        #expect(recovery.status == .stopped)
        shutdown.release(); await recovery.stop()
        #expect(engine.shutdownCount == 1)
        #expect(clock.pendingDelays.isEmpty)
    }
    @Test func remoteReadinessClearsPreviousResumeIntent() async {
        let gate = RecoveryFactoryGate(), clock = RecoveryTestClock()
        let recovery = coordinator(gate, clock)
        let snapshot = PlaybackRecoverySnapshot(wasActive: true, shouldResume: true, identity: identity, positionMs: 1000, volume: 0, shuffleEnabled: true, repeatMode: .off)
        recovery.start(recovery: snapshot); await gate.waitForCreationCount(1)
        #expect(gate.configurations[0].snapshot == snapshot)
        let remote = RecoveryStubEngine(); gate.succeedNext(with: remote); await settle(); remote.emit(.connectionReady(.remote)); await settle()
        remote.emit(.sessionLost(.spircEnded)); await gate.waitForCreationCount(2)
        #expect(gate.configurations[1].snapshot?.shouldResume != true)
        gate.failNext(with: .networkUnavailable); await settle(); await recovery.stop()
    }
    @Test func forcedRefreshBudgetSurvivesNetworkRetry() async {
        let gate = RecoveryFactoryGate(), clock = RecoveryTestClock(), calls = TokenLookups()
        let recovery = PlaybackRecoveryCoordinator(player: PlayerModel(), tokenProvider: { rejected in await calls.token(rejected) }, makeEngine: { _, options in try await gate.create(configuration: options) }, sleep: { try await clock.sleep(for: $0) }, randomUnit: { 1 })
        recovery.start(); await gate.waitForCreationCount(1); gate.failNext(with: .authExpired)
        await gate.waitForCreationCount(2); gate.failNext(with: .networkUnavailable); await settle()
        clock.advance(by: .seconds(2)); await gate.waitForCreationCount(3); gate.failNext(with: .authExpired); await settle()
        #expect(await calls.rejections == [nil, "OLD_FAKE", nil])
        #expect(recovery.status == .needsReauthentication)
        await recovery.stop()
    }

    @Test func staleRadioFailureCannotRestartTheReplacement() async {
        let gate = RecoveryFactoryGate(), clock = RecoveryTestClock(), engine = RecoveryStubEngine()
        let recovery = coordinator(gate, clock)
        recovery.start(); await gate.waitForCreationCount(1); gate.succeedNext(with: engine); await settle(); engine.emit(.connectionReady(.remote)); await settle()
        recovery.reportSessionLoss(.commandFailed, epoch: recovery.player.engineEpoch &- 1)
        await settle()
        #expect(recovery.status == .ready)
        #expect(gate.configurations.count == 1)
        await recovery.stop()
    }

    @Test func duplicateLossCoalescesAndOldShutdownPrecedesCreate() async {
        let gate = RecoveryFactoryGate(), clock = RecoveryTestClock(), old = RecoveryStubEngine()
        let recovery = coordinator(gate, clock)
        recovery.start(); await gate.waitForCreationCount(1); gate.succeedNext(with: old)
        await settle(); old.emit(.connectionReady(.remote)); await settle()
        old.emit(.sessionLost(.spircEnded)); old.emit(.sessionLost(.playerChannelClosed))
        await gate.waitForCreationCount(2)
        #expect(old.shutdownCount == 1)
        #expect(gate.maximumConcurrentCreations == 1)
        #expect(gate.configurations.allSatisfy { $0.deviceID == "stable" })
        let next = RecoveryStubEngine(); gate.succeedNext(with: next); await settle(); next.emit(.connectionReady(.remote)); await settle()
        #expect(recovery.status == .ready)
        await recovery.stop()
    }
    @Test func offlineSuspendsAndNetworkWakeRetryCoalesce() async {
        let gate = RecoveryFactoryGate(), clock = RecoveryTestClock()
        let recovery = coordinator(gate, clock)
        recovery.setNetworkAvailable(false); recovery.start(); await settle()
        #expect(gate.configurations.isEmpty)
        #expect(recovery.status == .offline)
        recovery.setNetworkAvailable(true); recovery.wake(); recovery.retryNow()
        await gate.waitForCreationCount(1)
        let engine = RecoveryStubEngine(); gate.succeedNext(with: engine); await settle(); engine.emit(.connectionReady(.remote)); await settle()
        recovery.wake(); await settle()
        #expect(gate.configurations.count == 1)
        #expect(gate.configurations[0].startup == .coldLaunch)
        await recovery.stop()
    }
    @Test func readinessTimesOutAt20SecondsAndStartupResolvedIsInsufficient() async {
        let gate = RecoveryFactoryGate(), clock = RecoveryTestClock(), engine = RecoveryStubEngine()
        let recovery = coordinator(gate, clock)
        recovery.start(); await gate.waitForCreationCount(1); gate.succeedNext(with: engine); await settle()
        engine.emit(.startupResolved(.restored)); await settle()
        #expect(recovery.status == .restoring)
        clock.advance(by: .seconds(20)); await settle()
        #expect(engine.shutdownCount == 1)
        #expect(recovery.status == .reconnecting)
        #expect(clock.pendingDelays.contains(.seconds(2)))
        await recovery.stop()
    }
    @Test func stopDuringCreateDestroysLateEngineWithoutAttaching() async {
        let gate = RecoveryFactoryGate(), clock = RecoveryTestClock(), engine = RecoveryStubEngine()
        let recovery = coordinator(gate, clock)
        recovery.start(); await gate.waitForCreationCount(1)
        recovery.invalidate()
        let stopped = Task { await recovery.stop() }
        gate.succeedNext(with: engine)
        await stopped.value
        #expect(engine.shutdownCount == 1)
        #expect(recovery.currentEngine == nil)
        #expect(!recovery.player.isEngineReady)
        #expect(recovery.status == .stopped)
    }
    @Test func sleepSuspendsDelayUntilWake() async {
        let gate = RecoveryFactoryGate(), clock = RecoveryTestClock()
        let recovery = coordinator(gate, clock)
        recovery.start(); await gate.waitForCreationCount(1); gate.failNext(with: .networkUnavailable); await settle()
        recovery.setSleeping(true); await settle(); clock.advance(by: .seconds(30)); await settle()
        #expect(gate.configurations.count == 1)
        recovery.wake(); await gate.waitForCreationCount(2)
        let engine = RecoveryStubEngine(); gate.succeedNext(with: engine); await settle(); engine.emit(.connectionReady(.unavailable)); await settle()
        #expect(recovery.status == .ready)
        #expect(recovery.player.restorationUnavailable)
        await recovery.stop()
    }
    @Test(arguments: [PlayerError.authDenied, .authExpired]) func networkChangesPreservePermanentFailure(_ error: PlayerError) async {
        let gate = RecoveryFactoryGate(), clock = RecoveryTestClock()
        let recovery = coordinator(gate, clock)
        recovery.start(); await gate.waitForCreationCount(1); gate.failNext(with: error)
        if error == .authExpired {
            await gate.waitForCreationCount(2); gate.failNext(with: error)
        }
        await settle()
        let expected: PlaybackConnectionStatus = .needsReauthentication
        let creations = gate.configurations.count
        #expect(recovery.status == expected)
        recovery.setNetworkAvailable(false); await settle()
        #expect(recovery.status == expected)
        recovery.retryNow(); await settle()
        #expect(recovery.status == expected && gate.configurations.count == creations)
        recovery.setNetworkAvailable(true); recovery.wake(); recovery.retryNow(); await settle()
        #expect(recovery.status == expected)
        #expect(gate.configurations.count == creations)
        recovery.invalidate()
        if gate.configurations.count > creations { gate.failNext(with: error) }
        await recovery.stop()
    }

    @Test(arguments: [PlayerError.credentialUnavailable, .credentialAccessDenied, .credentialSaveFailed])
    func credentialFailuresRequireExplicitRetry(_ error: PlayerError) async {
        let gate = RecoveryFactoryGate(), clock = RecoveryTestClock()
        let recovery = coordinator(gate, clock)
        recovery.start(); await gate.waitForCreationCount(1); gate.failNext(with: error); await settle()
        #expect(recovery.status == .failed(error))
        recovery.setNetworkAvailable(false); recovery.setNetworkAvailable(true); recovery.wake()
        clock.advance(by: .seconds(60)); await settle()
        #expect(recovery.status == .failed(error) && gate.configurations.count == 1)
        recovery.retryNow(); await settle()
        #expect(gate.configurations.count == 2)
        if gate.configurations.count == 2 { gate.failNext(with: error) }
        await recovery.stop()
    }

    @Test(arguments: [true, false]) func explicitPlaybackResolvesUnavailableAndReplacesSnapshot(_ playing: Bool) async {
        let gate = RecoveryFactoryGate(), clock = RecoveryTestClock()
        let recovery = coordinator(gate, clock)
        let original = PlaybackRecoverySnapshot(wasActive: true, shouldResume: true, identity: identity,
            positionMs: 1000, volume: 0, shuffleEnabled: true, repeatMode: .off)
        recovery.start(recovery: original); await gate.waitForCreationCount(1)
        let engine = RecoveryStubEngine(); gate.succeedNext(with: engine); await settle()
        engine.emit(.connectionReady(.unavailable)); await settle()
        #expect(recovery.player.restorationUnavailable)
        let newTrack = Track(uri: SpotifyURI("spotify:track:4uLU6hMCjMI75M1A2tKUQC")!, title: "New selection",
            artists: [], albumTitle: nil, artwork: nil, durationMs: 200_000)
        let newIdentity = PlaybackIdentity(trackURI: newTrack.uri, trackUID: "new-occurrence", contextURI: "spotify:playlist:new")
        recovery.player.load(PlayRequest(contextURI: newTrack.uri)); await settle()
        #expect(engine.recordedCommands == ["load"])
        engine.emit(.trackChanged(newTrack)); engine.emit(.recoveryIdentity(newIdentity))
        engine.emit(playing ? .playing(positionMs: 5000) : .paused(positionMs: 5000)); await settle()
        #expect(!recovery.player.restorationUnavailable)
        #expect(recovery.status == .ready)
        engine.emit(.sessionLost(.spircEnded)); await gate.waitForCreationCount(2)
        let snapshot = gate.configurations[1].snapshot
        #expect(snapshot?.identity == newIdentity)
        #expect(snapshot?.shouldResume == playing)
        #expect(snapshot?.wasActive == true)
        #expect((snapshot?.positionMs ?? 0) >= 5000)
        gate.failNext(with: .networkUnavailable); await settle(); await recovery.stop()
    }
}
private actor TokenLookups {
    var rejections: [String?] = []
    func token(_ rejected: String?) -> String { rejections.append(rejected); return rejected == nil ? "OLD_FAKE" : "NEW_FAKE" }
}

@MainActor private final class RecoverySuspension {
    private var continuation: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0; observer?.resume(); observer = nil } }
    func entered() async { if continuation != nil { return }; await withCheckedContinuation { observer = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
