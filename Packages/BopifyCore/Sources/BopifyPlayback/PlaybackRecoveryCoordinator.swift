import Foundation
import Observation
import BopifyDomain

public enum PlaybackConnectionStatus: Equatable, Sendable {
    case connecting, restoring, ready, reconnecting, offline, needsReauthentication
    case failed(PlayerError)
    case stopped
}

/// Nominal seconds before each retry: a first drop reconnects at once, repeated trouble escalates to five minutes.
let recoveryRetrySchedule: [Double] = [0, 2, 5, 15, 30, 60, 120, 300]
/// Drops older than this stop counting, so a session that recovers for good starts again from an immediate retry.
let recoveryDropWindow: TimeInterval = 600
/// Waits this long or longer offer the listener a manual retry.
let manualRetryThreshold: Double = 30

func recoveryRetryDelay(step: Int, jitterUnit: Double) -> Duration {
    let nominal = recoveryRetrySchedule[min(max(0, step), recoveryRetrySchedule.count - 1)]
    let unit = jitterUnit.isFinite ? min(1, max(0, jitterUnit)) : 0.5
    return .seconds(nominal * (0.5 + 0.5 * unit))
}

@MainActor @Observable
public final class PlaybackRecoveryCoordinator {
    public let player: PlayerModel
    public private(set) var status: PlaybackConnectionStatus = .stopped {
        didSet {
            guard oldValue != status else { return }
            BopifyLog.playback.info("connection status=\(String(describing: self.status), privacy: .public) generation=\(self.generation, privacy: .public)")
        }
    }
    public private(set) var currentEngine: (any ManagedPlaybackEngine)?
    @ObservationIgnored public var onEngineChange: (@MainActor ((any ManagedPlaybackEngine)?) -> Void)?
    @ObservationIgnored private let tokenProvider: @Sendable (String?) async throws -> String
    @ObservationIgnored private let makeEngine: @Sendable (String, PlaybackEngineConfiguration) async throws -> any ManagedPlaybackEngine
    @ObservationIgnored private let deviceID: String
    @ObservationIgnored private let now: @MainActor () -> TimeInterval
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let randomUnit: @Sendable () -> Double
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var workerID: UUID?
    @ObservationIgnored private var cleanup: Task<Void, Never>?
    @ObservationIgnored private var delay: Task<Void, Error>?
    @ObservationIgnored private var deadline: Task<Void, Never>?
    @ObservationIgnored private var wakeWaiter: AsyncStream<Void>.Continuation?
    @ObservationIgnored private var bootstrap: AsyncStream<BootstrapSignal>.Continuation?
    private enum BootstrapSignal: Sendable { case ready(PlaybackBootstrapOutcome), lost(SessionLossReason) }
    private var generation: UInt64 = 0
    private var active = false
    private var networkAvailable = true
    private var sleeping = false
    public private(set) var hasBeenReady = false
    private var snapshot: PlaybackRecoverySnapshot?
    private var recentDrops: [TimeInterval] = []
    private var connectFailures = 0
    private var retryStep = 0
    public private(set) var offersManualRetry = false
    private var retryBeforeCreate = false
    private var forcedRefreshUsed = false
    private var rejectedToken: String?

    public init(player: PlayerModel,
                tokenProvider: @escaping @Sendable (String?) async throws -> String,
                makeEngine: @escaping @Sendable (String, PlaybackEngineConfiguration) async throws -> any ManagedPlaybackEngine,
                deviceID: String = UUID().uuidString,
                now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                randomUnit: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }) {
        self.player = player
        self.tokenProvider = tokenProvider
        self.makeEngine = makeEngine
        self.deviceID = deviceID
        self.now = now
        self.sleep = sleep
        self.randomUnit = randomUnit
        player.onSessionLost = { [weak self] reason, snapshot in
            guard let self else { return }
            if self.snapshot == nil, self.hasBeenReady { self.snapshot = snapshot }
            self.reportSessionLoss(reason, epoch: self.player.engineEpoch)
        }
        player.onConnectionReady = { [weak self] outcome in self?.bootstrap?.yield(.ready(outcome)) }
        player.onRestorationResolved = { [weak self] in self?.snapshot = nil }
    }

    public func start(recovery: PlaybackRecoverySnapshot? = nil) {
        generation &+= 1
        active = true
        if let recovery { snapshot = recovery; hasBeenReady = true }
        forcedRefreshUsed = false
        rejectedToken = nil
        // A new session starts from the first rung; state left by an earlier session must not delay it.
        retryBeforeCreate = false
        connectFailures = 0
        recentDrops = []
        offersManualRetry = false
        delay?.cancel()
        worker?.cancel()
        let previous = worker
        launch(after: previous)
    }

    public func retryNow() {
        guard active else { return }
        if case .needsReauthentication = status { return }
        if status == .ready && !player.restorationUnavailable { return }
        retryBeforeCreate = false
        delay?.cancel()
        wakeWaiter?.yield(())
        if worker == nil { launch() }
    }

    public func setNetworkAvailable(_ available: Bool) {
        guard networkAvailable != available else { return }
        networkAvailable = available
        switch status {
        case .needsReauthentication, .failed: return
        default: break
        }
        if status != .ready && active && !available { status = .offline }
        delay?.cancel()
        wakeWaiter?.yield(())
        if available { retryNow() }
    }

    public func setSleeping(_ value: Bool) {
        sleeping = value
        delay?.cancel()
        wakeWaiter?.yield(())
    }

    public func wake() {
        setSleeping(false)
        if case .failed = status { return }
        retryNow()
    }

    public func reportSessionLoss(_ reason: SessionLossReason, epoch: UInt64) {
        guard active, epoch == player.engineEpoch, currentEngine != nil else { return }
        guard bootstrap != nil || status == .ready else { return }
        if snapshot == nil, hasBeenReady { snapshot = player.captureRecoverySnapshot(at: .now) }
        if bootstrap == nil {
            recentDrops.append(now())
            retryStep = dropStep()
            retryBeforeCreate = retryStep > 0
        }
        player.detachEngine()
        status = networkAvailable ? .reconnecting : .offline
        BopifyLog.playback.error("recovery requested reason=\(reason.rawValue, privacy: .public) epoch=\(epoch, privacy: .public)")
        if let bootstrap { bootstrap.yield(.lost(reason)) }
        else if worker == nil { launch() }
    }

    public func invalidate() {
        guard active else { return }
        active = false
        generation &+= 1
        status = .stopped
        worker?.cancel()
        delay?.cancel(); deadline?.cancel()
        wakeWaiter?.finish(); bootstrap?.finish()
        player.detachEngine()
        if let engine = currentEngine {
            currentEngine = nil
            onEngineChange?(nil)
            let previous = cleanup
            cleanup = Task { await previous?.value; await engine.shutdown() }
        }
        snapshot = nil
    }

    public func stop() async {
        invalidate()
        await worker?.value
        await cleanup?.value
    }

    private func launch(after previous: Task<Void, Never>? = nil) {
        let id = UUID(), mine = generation
        workerID = id
        worker = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await cleanup?.value
            defer { if workerID == id { worker = nil; workerID = nil } }
            await run(generation: mine)
        }
    }

    private func live(_ mine: UInt64) -> Bool { active && generation == mine && !Task.isCancelled }

    private func tearDownCurrent() async {
        guard let engine = currentEngine else { return }
        player.detachEngine()
        currentEngine = nil
        onEngineChange?(nil)
        let started = now()
        await engine.shutdown()
        BopifyLog.playback.info("recovery teardown elapsed=\(self.now() - started, privacy: .public)")
    }

    private func run(generation mine: UInt64) async {
        while live(mine) {
            await tearDownCurrent()
            guard live(mine) else { return }
            if !networkAvailable || sleeping {
                status = networkAvailable ? .reconnecting : .offline
                let (events, waiter) = AsyncStream<Void>.makeStream()
                wakeWaiter = waiter
                for await _ in events { break }
                wakeWaiter = nil
                continue
            }
            if retryBeforeCreate {
                retryBeforeCreate = false
                await waitForRetry()
                guard live(mine) else { return }
                if !networkAvailable || sleeping { continue }
            }
            status = hasBeenReady ? .reconnecting : .connecting
            let started = now()
            var token: String?
            do {
                token = try await tokenProvider(rejectedToken)
                guard live(mine) else { return }
                rejectedToken = nil
                let options = PlaybackEngineConfiguration(deviceID: deviceID, startup: hasBeenReady ? .recovery : .coldLaunch,
                    snapshot: hasBeenReady ? snapshot : nil, initialVolume: player.preferredVolume)
                let engine = try await makeEngine(token!, options)
                guard live(mine), networkAvailable, !sleeping else { await engine.shutdown(); continue }
                BopifyLog.playback.info("recovery engine created elapsed=\(self.now() - started, privacy: .public)")
                currentEngine = engine
                let (events, continuation) = AsyncStream<BootstrapSignal>.makeStream()
                bootstrap = continuation
                player.attachEngine(engine, epoch: player.engineEpoch &+ 1)
                onEngineChange?(engine)
                status = .restoring
                let sleep = self.sleep
                deadline = Task {
                    do { try await sleep(.seconds(20)); continuation.yield(.lost(.readinessTimeout)) } catch {}
                }
                var iterator = events.makeAsyncIterator()
                let signal = await iterator.next()
                deadline?.cancel(); deadline = nil
                bootstrap = nil; continuation.finish()
                guard live(mine) else { return }
                switch signal {
                case let .ready(outcome):
                    guard player.isEngineReady else { throw PlayerError.playbackSessionLost }
                    hasBeenReady = true
                    if outcome != .unavailable { snapshot = nil }
                    forcedRefreshUsed = false
                    rejectedToken = nil
                    connectFailures = 0
                    status = .ready
                    return
                case let .lost(reason):
                    BopifyLog.playback.error("bootstrap lost reason=\(reason.rawValue, privacy: .public)")
                    throw PlayerError.playbackSessionLost
                case nil: return
                }
            } catch {
                guard live(mine) else { return }
                let error = error as? PlayerError ?? .unknown
                await tearDownCurrent()
                guard live(mine) else { return }
                if error == .authExpired {
                    if let token, !forcedRefreshUsed {
                        forcedRefreshUsed = true
                        rejectedToken = token
                        BopifyLog.auth.notice("playback token rejected, refreshing once")
                        continue
                    }
                    status = .needsReauthentication
                    return
                }
                if error == .authDenied { status = .needsReauthentication; return }
                guard error == .networkUnavailable || error == .playbackSessionLost else { status = .failed(error); return }
                connectFailures += 1
                retryStep = dropStep() + connectFailures
                status = networkAvailable ? .reconnecting : .offline
                guard networkAvailable, !sleeping else { continue }
                await waitForRetry()
            }
        }
    }

    /// Counts drops inside the window, so a session that keeps failing escalates however long each connection lasts.
    private func dropStep() -> Int {
        let cutoff = now() - recoveryDropWindow
        recentDrops.removeAll { $0 <= cutoff }
        return max(0, recentDrops.count - 1)
    }

    private func waitForRetry() async {
        let step = min(retryStep, recoveryRetrySchedule.count - 1)
        let retry = recoveryRetryDelay(step: step, jitterUnit: randomUnit())
        BopifyLog.playback.info("recovery retry step=\(step, privacy: .public) delay=\(String(describing: retry), privacy: .public)")
        offersManualRetry = recoveryRetrySchedule[step] >= manualRetryThreshold
        defer { offersManualRetry = false }
        let sleep = self.sleep
        let waiting = Task { try await sleep(retry) }
        delay = waiting
        try? await waiting.value
        delay = nil
    }
}
