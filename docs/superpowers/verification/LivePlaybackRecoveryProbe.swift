import AppKit
import Foundation
import Network
import BopifyAuth
import BopifyDomain
import BopifyPlayback

@main @MainActor struct LivePlaybackRecoveryProbe {
    enum CheckFailure: Error { case failed(String) }
    static func record(_ message: String) {
        FileHandle.standardOutput.write(Data("\(Date.now.ISO8601Format()) \(message)\n".utf8))
    }
    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw CheckFailure.failed(message) }
        record("PASS: \(message)")
    }
    static func wait(_ description: String, seconds: TimeInterval = 90, until condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw CheckFailure.failed("Timed out: \(description)") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    static func ready(_ coordinator: PlaybackRecoveryCoordinator, after epoch: UInt64 = 0) async throws {
        try await wait("native readiness") {
            coordinator.status == .ready && coordinator.player.engineEpoch > epoch
                || coordinator.status == .needsReauthentication
                || { if case .failed = coordinator.status { return true }; return false }()
        }
        try check(coordinator.status == .ready, "native session ready")
    }
    static func replace(_ coordinator: PlaybackRecoveryCoordinator) async throws {
        let epoch = coordinator.player.engineEpoch
        guard let engine = coordinator.currentEngine else { throw CheckFailure.failed("No native engine to terminate") }
        record("CHECK: controlled termination of this probe's native engine")
        await engine.shutdown()
        try await ready(coordinator, after: epoch)
    }
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in await run(); app.terminate(nil) }
        app.run()
    }
    @concurrent static func continueManualCheck() async { _ = readLine() }
    static func run() async {
        let store = KeychainTokenStore()
        guard let saved = store.load() else { record("BLOCKED: saved playback grant is inaccessible"); exit(77) }
        record("CHECK: saved grant found; expired=\(saved.expiresAt < .now), refreshAvailable=\(saved.refreshToken != nil)")
        let auth = SpotifyAuthService(clientID: librespotClientID, store: store, openURL: { _ in })
        let player = PlayerModel()
        let control = CreationControl()
        let coordinator = PlaybackRecoveryCoordinator(player: player, tokenProvider: { rejected in
            if let rejected { return try await auth.validAccessToken(rejecting: rejected) }
            return try await auth.validAccessToken()
        }, makeEngine: { token, options in
            await control.creating()
            while await control.hold { try await Task.sleep(for: .milliseconds(100)) }
            return try await LibrespotEngine(accessToken: token, deviceName: "Bopify Recovery Check",
                configuration: PlaybackEngineConfiguration(deviceID: options.deviceID, startup: .recovery, snapshot: options.snapshot))
        })
        var lossSnapshot: PlaybackRecoverySnapshot?
        let onSessionLost = player.onSessionLost
        player.onSessionLost = { reason, snapshot in
            lossSnapshot = snapshot
            record("CHECK: loss checkpoint active=\(snapshot.wasActive), resume=\(snapshot.shouldResume), identityPresent=\(snapshot.identity != nil)")
            onSessionLost?(reason, snapshot)
        }
        coordinator.onStatusChange = {
            record("STATE: \(String(describing: $0)), active=\(player.state.isActiveDevice), phase=\(String(describing: player.state.phase)), restorationUnavailable=\(player.restorationUnavailable)")
            if $0 == .ready, let lossSnapshot, let saved = lossSnapshot.identity, let recovered = player.recoveryIdentity {
                let uriMatches = saved.trackURI == recovered.trackURI
                let uidMatches = saved.trackUID == nil || saved.trackUID == "" || saved.trackUID == recovered.trackUID
                let contextMatches = saved.contextURI == nil || saved.contextURI == "" || saved.contextURI == recovered.contextURI
                record("CHECK: recovered identity uriMatches=\(uriMatches), uidMatches=\(uidMatches), contextMatches=\(contextMatches), requestedResume=\(lossSnapshot.shouldResume)")
            }
        }
        let platform = PlaybackConnectionMonitor(coordinator: coordinator)
        platform.start()
        defer { platform.stop() }
        var other: LibrespotEngine?
        var otherPlayer: PlayerModel?
        var baseline: PlaybackRecoverySnapshot?
        do {
            coordinator.start()
            try await ready(coordinator)
            guard let initialGrant = store.load() else { throw CheckFailure.failed("Refreshed grant inaccessible") }
            record("CHECK: initial grant expiry=\(initialGrant.expiresAt.ISO8601Format())")
            guard !player.restorationUnavailable else { throw CheckFailure.failed("No restorable Spotify session is available") }
            guard player.state.isActiveDevice else {
                try await replace(coordinator)
                try check(!player.state.isActiveDevice, "existing foreign owner preserved across native replacement")
                throw CheckFailure.failed("Local playback checks need an available local session; no takeover was requested")
            }
            guard player.recoveryIdentity != nil, player.state.currentTrack != nil else {
                throw CheckFailure.failed("No restorable track is available")
            }
            baseline = player.captureRecoverySnapshot(at: .now)
            if player.state.phase == .playing { player.togglePlayPause() }
            try await wait("paused local playback") { player.state.phase == .paused }
            player.setVolume(0)
            player.setRepeat(.track)
            try await wait("zero volume and repeat option") { player.state.volume == 0 && player.state.repeatMode == .track }
            let identity = player.recoveryIdentity
            let pausedPosition = player.displayPositionMs(at: .now)
            try await replace(coordinator)
            try check(player.state.phase == .paused && player.recoveryIdentity == identity, "paused occurrence restored without auto-resume")
            try check(abs(player.displayPositionMs(at: .now) - pausedPosition) < 1500, "paused position restored")
            try check(player.state.volume == 0 && player.state.repeatMode == .track, "zero volume and repeat preserved")
            player.togglePlayPause()
            try await wait("local playback started") { player.state.phase == .playing }
            try await replace(coordinator)
            try check(player.state.phase == .playing && player.recoveryIdentity == identity, "playing occurrence resumes after native replacement")

            if CommandLine.arguments.contains("--physical-check") {
                let signals = PhysicalSignals(coordinator: coordinator)
                defer { signals.stop() }
                record("WAIT: turn off the Mac network for 30 seconds, reconnect it, then confirm the network step")
                await continueManualCheck()
                record("CHECK: network confirmation status=\(String(describing: coordinator.status)), active=\(player.state.isActiveDevice), phase=\(String(describing: player.state.phase)), epoch=\(player.engineEpoch)")
                try check(signals.offlinePaths > 0, "physical network loss observed")
                try await wait("network return playback") { coordinator.status == .ready && player.state.isActiveDevice && player.state.phase == .playing }
                try check(signals.networkAvailable, "physical network return observed with local playback")
                let beforeSleep = player.engineEpoch
                record("WAIT: put this Mac to sleep for 20 seconds, wake it, then confirm the sleep step; this probe injects its own session loss on sleep")
                await continueManualCheck()
                try check(signals.sleeps > 0 && signals.wakes > 0, "physical sleep and wake observed")
                try await ready(coordinator, after: beforeSleep)
                try check(player.state.isActiveDevice && player.state.phase == .playing && player.state.volume == 0,
                    "local playback automatically resumes after physical wake and controlled session loss")
                guard await finish(coordinator, other: other, otherPlayer: otherPlayer, baseline: baseline, auth: auth) else { exit(77) }
                record("PASS: physical network and sleep recovery acceptance complete")
                return
            }

            // Both Connect clients belong to this probe; never request takeover from an unrelated owner.
            let token = try await auth.validAccessToken()
            let second = try await LibrespotEngine(accessToken: token, deviceName: "Bopify Ownership Check",
                configuration: PlaybackEngineConfiguration(deviceID: UUID().uuidString, startup: .recovery))
            other = second
            let secondaryPlayer = PlayerModel()
            otherPlayer = secondaryPlayer
            secondaryPlayer.attachEngine(second, epoch: 1)
            try await wait("secondary remote readiness") { secondaryPlayer.isEngineReady }
            try await wait("secondary remote playback metadata") { secondaryPlayer.canPlayHere }
            try check(!secondaryPlayer.state.isActiveDevice && secondaryPlayer.canPlayHere, "secondary client initially respects primary owner")
            try await second.setVolume(0)
            control.hold = true
            let creations = control.count
            let epoch = player.engineEpoch
            guard let engine = coordinator.currentEngine else { throw CheckFailure.failed("Primary engine missing") }
            await engine.shutdown()
            try await wait("replacement creation gate") { control.count > creations }
            secondaryPlayer.playHere()
            try await wait("controlled other-device takeover") { secondaryPlayer.state.isActiveDevice && secondaryPlayer.state.phase == .playing }
            control.hold = false
            try await ready(coordinator, after: epoch)
            try check(!player.state.isActiveDevice && secondaryPlayer.state.isActiveDevice, "takeover during replacement prevents automatic resume")
            try await replace(coordinator)
            try check(!player.state.isActiveDevice && secondaryPlayer.state.isActiveDevice, "foreign owner before replacement remains active")
            if CommandLine.arguments.contains("--cleanup-check"), let baseline {
                let temporaryRepeat: RepeatMode = baseline.repeatMode == .track ? .context : .track
                secondaryPlayer.setRepeat(temporaryRepeat)
                try await wait("temporary secondary repeat option") { secondaryPlayer.state.repeatMode == temporaryRepeat }
                guard await finish(coordinator, other: other, otherPlayer: otherPlayer, baseline: baseline, auth: auth) else { exit(77) }
                try check(secondaryPlayer.state.repeatMode == baseline.repeatMode, "cleanup restores options through the active secondary client")
                record("PASS: secondary-owner cleanup acceptance complete")
                return
            }
            secondaryPlayer.togglePlayPause()
            try await wait("secondary paused") { secondaryPlayer.state.phase == .paused }
            record("CHECK: primary takeover eligibility=\(player.canPlayHere), ready=\(player.isEngineReady), secondary active=\(secondaryPlayer.state.isActiveDevice)")
            player.playHere()
            try await wait("explicit local takeover after controlled check") { player.state.isActiveDevice && player.state.phase == .playing }
            secondaryPlayer.stop()
            await second.shutdown()
            other = nil
            otherPlayer = nil
            player.setVolume(0)
            try await wait("quiet local playback") { player.state.volume == 0 }

            let observationStart = ProcessInfo.processInfo.systemUptime
            for minute in 1...65 {
                try await Task.sleep(for: .seconds(60))
                try check(coordinator.status == .ready && player.state.isActiveDevice && player.state.phase == .playing,
                    "observed local playback minute=\(minute), epoch=\(player.engineEpoch)")
            }
            try check(Date.now > initialGrant.expiresAt && ProcessInfo.processInfo.systemUptime - observationStart >= 3900,
                "65-minute playback passed initial OAuth expiry")
            try await replace(coordinator)
            try check(player.state.phase == .playing, "playback recovery after initial OAuth expiry")
            try check((store.load()?.expiresAt ?? .distantPast) > initialGrant.expiresAt, "replacement refreshed persisted playback grant")
            guard await finish(coordinator, other: other, otherPlayer: otherPlayer, baseline: baseline, auth: auth) else { exit(77) }
            record("PASS: live acceptance complete; host network and physical sleep were not changed")
        } catch {
            control.hold = false
            record("CHECK: failure status=\(String(describing: coordinator.status)), active=\(player.state.isActiveDevice), phase=\(String(describing: player.state.phase)), epoch=\(player.engineEpoch)")
            if case let CheckFailure.failed(message) = error { record("BLOCKED: \(message)") }
            else if let error = error as? PlayerError { record("BLOCKED: \(String(describing: error))") }
            else { record("BLOCKED: unclassified live service failure") }
            _ = await finish(coordinator, other: other, otherPlayer: otherPlayer, baseline: baseline, auth: auth)
            exit(77)
        }
    }
    static func finish(_ coordinator: PlaybackRecoveryCoordinator, other: LibrespotEngine?, otherPlayer: PlayerModel?, baseline: PlaybackRecoverySnapshot?, auth: SpotifyAuthService) async -> Bool {
        var restored = true
        let player = [coordinator.player, otherPlayer].compactMap { $0 }.first { $0.isEngineReady && $0.state.isActiveDevice }
        if let player, let baseline {
            do {
                if player.state.phase == .playing { player.togglePlayPause() }
                try await wait("cleanup pause", seconds: 10) { player.state.phase == .paused }
                player.setVolume(baseline.volume)
                try await wait("cleanup volume", seconds: 10) { abs(player.state.volume - baseline.volume) < 0.001 }
                player.setShuffle(baseline.shuffleEnabled)
                try await wait("cleanup shuffle", seconds: 10) { player.state.shuffleEnabled == baseline.shuffleEnabled }
                player.setRepeat(baseline.repeatMode)
                try await wait("cleanup repeat", seconds: 10) { player.state.repeatMode == baseline.repeatMode }
                player.seek(to: baseline.positionMs)
                try await wait("cleanup position", seconds: 10) { abs(player.displayPositionMs(at: .now) - baseline.positionMs) < 1500 }
                record("CHECK: captured playback options and position restored")
            } catch {
                restored = false
                record("BLOCKED: cleanup could not restore all captured playback settings")
            }
        } else if baseline != nil {
            record("CHECK: no active probe client; cleanup leaves foreign playback alone")
        }
        otherPlayer?.stop()
        if let other { await other.shutdown() }
        await coordinator.stop()
        await auth.cancelPendingWork()
        record("CHECK: probe native engines stopped; saved authorization retained")
        return restored
    }
}

@MainActor private final class CreationControl {
    var hold = false
    var count = 0
    func creating() { count += 1 }
}

@MainActor private final class PhysicalSignals {
    var offlinePaths = 0
    var networkAvailable = true
    var sleeps = 0
    var wakes = 0
    private let path = NWPathMonitor()
    private var observers: [NSObjectProtocol] = []
    init(coordinator: PlaybackRecoveryCoordinator) {
        path.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                self.networkAvailable = available
                if !available { self.offlinePaths += 1 }
                LivePlaybackRecoveryProbe.record("CHECK: physical network available=\(available), active=\(coordinator.player.state.isActiveDevice), phase=\(String(describing: coordinator.player.state.phase)), epoch=\(coordinator.player.engineEpoch)")
            }
        }
        path.start(queue: DispatchQueue(label: "bopify.probe.path"))
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.sleeps += 1
                LivePlaybackRecoveryProbe.record("CHECK: physical sleep notification; inject controlled session loss")
                coordinator.reportSessionLoss(.legacy, epoch: coordinator.player.engineEpoch)
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.wakes += 1
                LivePlaybackRecoveryProbe.record("CHECK: physical wake notification")
            }
        })
    }
    func stop() {
        path.cancel()
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers = []
    }
}
