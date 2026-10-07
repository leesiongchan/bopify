import Foundation
import Observation
import os
import BopifyDomain

public enum QueueSelectionStatus: Equatable, Sendable {
    case idle
    case pending(entryID: String, target: QueueTarget)
    case confirmed(entryID: String, target: QueueTarget)
    case failed
}

/// Folds engine events into observable state on the main actor.
///
/// Deliberately not an actor: this folds events into state that SwiftUI
/// observes, so it belongs on the main actor. Blocking FFI work stays off
/// it because `LibrespotEngine`'s methods are nonisolated and this package
/// does not enable NonisolatedNonsendingByDefault, so awaiting them hops to
/// the global executor.
@MainActor
@Observable
public final class PlayerModel {
    public private(set) var engineEpoch: UInt64 = 0
    public private(set) var isEngineReady = false
    public private(set) var restorationUnavailable = false
    @ObservationIgnored public var onSessionLost: (@MainActor (SessionLossReason, PlaybackRecoverySnapshot) -> Void)?
    @ObservationIgnored private var managedAttachment = false
    @ObservationIgnored private var reportedLoss = false
    @ObservationIgnored private var stagedEvents: [PlaybackEvent] = []
    private var lastConfirmedPlaying = false
    public private(set) var recoveryIdentity: PlaybackIdentity?
    @ObservationIgnored public var onConnectionReady: (@MainActor (PlaybackBootstrapOutcome) -> Void)?
    public private(set) var state = PlaybackState()
    public private(set) var commandNotice: String?
    public private(set) var queueSelection: QueueSelectionStatus = .idle
    private var lastPositiveVolume: Double?
    private var volumeDraft: Double?
    private var isEditingVolume = false
    public var displayVolume: Double { volumeDraft ?? state.volume }
    private(set) var positionUpdatedAt = Date.now
    private(set) var remoteUpdatedAt = Date.now
    private var frozenDisplayPositionMs: Int64?

    @ObservationIgnored private var engine: (any PlaybackEngine)?
    @ObservationIgnored private var consumer: Task<Void, Never>?
    @ObservationIgnored private var pendingCommand: Task<Void, Never>?
    @ObservationIgnored private var commandGeneration: UInt64 = 0
    @ObservationIgnored private var volumeRequest: (value: Double, immediate: Bool)?
    @ObservationIgnored private var volumeTask: Task<Void, Never>?
    @ObservationIgnored private var volumeDelay: Task<Void, Error>?
    @ObservationIgnored private var volumeGeneration: UInt64 = 0
    @ObservationIgnored private var lastVolumeSent: Double?
    @ObservationIgnored private var volumeDispatchedAt: TimeInterval?
    @ObservationIgnored private let volumeNow: @MainActor () -> TimeInterval
    @ObservationIgnored private let volumeSleep: @Sendable (Duration) async throws -> Void

    public convenience init() {
        self.init(engine: nil, volumeNow: { ProcessInfo.processInfo.systemUptime }, volumeSleep: { try await Task.sleep(for: $0) })
    }

    public convenience init(engine: any PlaybackEngine) {
        self.init(engine: engine, volumeNow: { ProcessInfo.processInfo.systemUptime },
                  volumeSleep: { try await Task.sleep(for: $0) })
    }

    init(engine: (any PlaybackEngine)?, volumeNow: @escaping @MainActor () -> TimeInterval,
         volumeSleep: @escaping @Sendable (Duration) async throws -> Void) {
        self.engine = engine
        self.isEngineReady = engine != nil
        self.volumeNow = volumeNow
        self.volumeSleep = volumeSleep
    }

    /// Interpolate for display without replacing the engine's authoritative position.
    /// A mirrored device's own clock takes precedence while Bopify is inactive.
    public func displayPositionMs(at date: Date) -> Int64 {
        if let remote = state.mirror {
            let elapsed = remote.isPlaying ? max(0, date.timeIntervalSince(remoteUpdatedAt)) * 1000 : 0
            let position = Double(remote.positionMs) + elapsed
            // Clamped only to a reported duration, as the Rust extraction is.
            return Int64(remote.durationMs > 0 ? min(Double(remote.durationMs), position) : position)
        }
        let elapsed = state.phase == .playing ? max(0, date.timeIntervalSince(positionUpdatedAt)) * 1000 : 0
        let position = min(Double(max(0, state.durationMs)), max(0, Double(frozenDisplayPositionMs ?? state.positionMs) + elapsed))
        return Int64(position)
    }

    public var displayDurationMs: Int64 { state.mirror?.durationMs ?? state.durationMs }

    /// Views run a display clock only while this is true.
    public var isPositionAdvancing: Bool { isEngineReady && (state.mirror?.isPlaying ?? (state.phase == .playing)) }

    /// One consumer for the model's lifetime. A per-view .task would
    /// resubscribe whenever view identity changed.
    public func start() {
        guard consumer == nil, let engine else { return }
        let epoch = engineEpoch
        BopifyLog.playback.info("player model starting epoch=\(epoch, privacy: .public)")
        consumer = Task { [weak self] in
            for await event in engine.events {
                guard let self, !Task.isCancelled, engineEpoch == epoch else { return }
                if reportedLoss && (managedAttachment || onSessionLost != nil) { continue }
                if managedAttachment && !isEngineReady {
                    switch event {
                    case .sessionLost, .failed(.playbackSessionLost), .connectionReady, .recoveryIdentity: apply(event)
                    default: stagedEvents.append(event)
                    }
                } else { apply(event) }
            }
            guard let self, !Task.isCancelled, engineEpoch == epoch else { return }
            reportSessionLoss(.eventStreamEnded)
        }
    }

    public func attachEngine(_ engine: any PlaybackEngine, epoch: UInt64) {
        detachEngine()
        engineEpoch = epoch
        self.engine = engine
        managedAttachment = true
        reportedLoss = false
        stagedEvents = []
        restorationUnavailable = false
        recoveryIdentity = nil
        start()
    }

    public func detachEngine() {
        freezeDisplayPosition()
        stop()
        volumeTask?.cancel()
        volumeTask = nil
        engine = nil
        isEngineReady = false
        stagedEvents = []
        state.isActiveDevice = false
        if let remote = state.remote { state.staleRemote = stalled(remote); state.remote = nil }
        if state.phase == .playing || state.phase == .loading { state.phase = .idle }
    }

    public func setConnectionReady(_ outcome: PlaybackBootstrapOutcome) {
        guard !reportedLoss else { return }
        isEngineReady = true
        restorationUnavailable = outcome == .unavailable
        let pending = stagedEvents
        stagedEvents = []
        if outcome != .unavailable { pending.forEach(apply) }
        switch outcome {
        case let .local(identity): recoveryIdentity = identity; state.isActiveDevice = true
        case .remote: state.isActiveDevice = false; lastConfirmedPlaying = false
        case .unavailable: state.isActiveDevice = false; state.phase = .idle; lastConfirmedPlaying = false
        }
        onConnectionReady?(outcome)
    }

    public func captureRecoverySnapshot(at date: Date) -> PlaybackRecoverySnapshot {
        let identity = recoveryIdentity.flatMap { $0.trackURI == state.currentTrack?.uri ? $0 : nil }
        return PlaybackRecoverySnapshot(wasActive: state.isActiveDevice,
            shouldResume: state.isActiveDevice && lastConfirmedPlaying && identity != nil,
            identity: identity, positionMs: displayPositionMs(at: date), volume: state.volume,
            shuffleEnabled: state.shuffleEnabled, repeatMode: state.repeatMode)
    }

    private func reportSessionLoss(_ reason: SessionLossReason) {
        guard !reportedLoss else { return }
        let snapshot = captureRecoverySnapshot(at: .now)
        reportedLoss = true
        isEngineReady = false
        commandGeneration &+= 1
        pendingCommand?.cancel()
        cancelVolumeEditing()
        apply(.failed(.playbackSessionLost))
        BopifyLog.playback.error("player session lost reason=\(reason.rawValue, privacy: .public) epoch=\(self.engineEpoch, privacy: .public)")
        onSessionLost?(reason, snapshot)
    }

    #if DEBUG
    /// Folds events at once instead of through the engine's stream, so a preview's first frame already shows its scenario.
    public func applyPreviewEvents(_ events: [PlaybackEvent]) { events.forEach(apply) }
    #endif

    public func stop() {
        cancelVolumeEditing()
        queueSelection = .idle
        lastPositiveVolume = nil
        guard consumer != nil else { return }
        BopifyLog.playback.info("player model stopping")
        consumer?.cancel()
        consumer = nil
        commandGeneration &+= 1
        pendingCommand?.cancel()
        pendingCommand = nil
    }

    /// Play takes the session over while Bopify is inactive, from a mirror or a stale track.
    public var canPlayHere: Bool {
        guard isEngineReady, !state.isActiveDevice, state.mirror != nil || state.currentTrack != nil else { return false }
        if case .error = state.phase { return false }
        return true
    }

    public func playHere() {
        guard isEngineReady, let engine else { return; }
        guard canPlayHere else { return }
        enqueue("playHere") { [engine] in try await engine.playHere() }
    }

    public func togglePlayPause() {
        guard isEngineReady, let engine else { return; }
        guard state.isActiveDevice else { playHere(); return }
        let shouldPause = state.phase == .playing
        enqueue(shouldPause ? "pause" : "resume", requiresActive: true) { [engine] in
            if shouldPause { try await engine.pause() } else { try await engine.resume() }
        }
    }

    public func next() {
        guard isEngineReady, let engine else { return; }
        guard state.isActiveDevice, state.canNext else { return }
        enqueue("next", requiresActive: true) { [engine] in try await engine.next() }
    }

    public func previous() {
        guard isEngineReady, let engine else { return; }
        guard state.isActiveDevice, state.canPrevious else { return }
        enqueue("previous", requiresActive: true) { [engine] in try await engine.previous() }
    }

    public func load(_ request: PlayRequest) {
        guard isEngineReady, let engine else { return; }
        enqueue("load") { [engine] in try await engine.load(request) }
    }

    public func seek(to milliseconds: Int64) {
        guard isEngineReady, let engine else { return; }
        guard state.isActiveDevice, state.canSeek, state.durationMs > 0 else { return }
        let target = min(max(0, milliseconds), state.durationMs)
        enqueue("seek", requiresActive: true) { [engine] in try await engine.seek(to: target) }
    }

    public func seek(by milliseconds: Int64) {
        let (target, overflow) = displayPositionMs(at: .now).addingReportingOverflow(milliseconds)
        seek(to: overflow ? (milliseconds > 0 ? state.durationMs : 0) : target)
    }

    public func selectQueueEntry(_ target: QueueTarget) {
        guard isEngineReady, let engine else { return; }
        guard isEngineReady, consumer != nil, state.isActiveDevice else { return }
        guard target.engineEpoch == engineEpoch, state.queue?.generation == target.generation,
              let entry = state.queue?.next.first(where: { $0.target == target }) else {
            queueSelection = .failed
            commandNotice = String(localized: "queue.changed", defaultValue: "The queue changed. Choose the track again.")
            return
        }
        let selection = QueueSelectionStatus.pending(entryID: entry.id, target: target)
        guard queueSelection != selection else { return }
        queueSelection = selection
        commandNotice = nil
        enqueue("selectQueue", requiresActive: true, selection: selection) { [engine] in try await engine.selectQueueEntry(target) }
    }

    public func setShuffle(_ enabled: Bool) {
        guard isEngineReady, let engine else { return; }
        guard state.isActiveDevice else { return }
        enqueue("setShuffle", requiresActive: true) { [engine] in try await engine.setShuffle(enabled) }
    }

    public func setRepeat(_ mode: RepeatMode) {
        guard isEngineReady, let engine else { return; }
        guard state.isActiveDevice else { return }
        enqueue("setRepeat", requiresActive: true) { [engine] in try await engine.setRepeat(mode) }
    }

    public func setVolume(_ value: Double) {
        guard isEngineReady, consumer != nil, state.isActiveDevice, value.isFinite else { return }
        let volume = max(0, min(1, value))
        guard volume != (volumeRequest?.value ?? volumeDraft ?? state.volume) else { return }
        volumeDraft = volume
        volumeRequest = (volume, false)
        startVolumeWorker()
    }

    public func beginVolumeEditing() {
        guard isEngineReady, consumer != nil, state.isActiveDevice else { return }
        isEditingVolume = true
        volumeDraft = volumeDraft ?? state.volume
    }

    public func endVolumeEditing() {
        isEditingVolume = false
        if let request = volumeRequest { volumeRequest = (request.value, true) }
        else if let draft = volumeDraft, draft != (lastVolumeSent ?? state.volume) { volumeRequest = (draft, true) }
        volumeDelay?.cancel()
        if volumeRequest != nil { startVolumeWorker() }
        if volumeDraft == state.volume && volumeRequest == nil && volumeTask == nil { volumeDraft = nil }
    }

    public func cancelVolumeEditing() {
        isEditingVolume = false
        volumeDraft = nil
        volumeRequest = nil
        volumeGeneration &+= 1
        volumeDelay?.cancel()
        lastVolumeSent = nil
        volumeDispatchedAt = nil
    }

    public func toggleMute() {
        setVolume(state.volume > 0 ? 0 : (lastPositiveVolume ?? 0.5))
        endVolumeEditing()
    }

    private func startVolumeWorker() {
        guard volumeTask == nil else { return }
        guard isEngineReady, let engine else { return }
        let epoch = engineEpoch
        volumeTask = Task { [weak self] in await self?.drainVolume(engine: engine, epoch: epoch) }
    }

    private func drainVolume(engine: any PlaybackEngine, epoch: UInt64) async {
        defer { if engineEpoch == epoch { volumeTask = nil } }
        while !Task.isCancelled, engineEpoch == epoch, let request = volumeRequest {
            if !request.immediate, let last = volumeDispatchedAt {
                let delay = last + 0.150 - volumeNow()
                if delay > 0 {
                    let sleep = volumeSleep
                    let wait = Task { try await sleep(.seconds(delay)) }
                    volumeDelay = wait
                    try? await wait.value
                    volumeDelay = nil
                    continue
                }
            }
            volumeRequest = nil
            guard isEngineReady, engineEpoch == epoch, consumer != nil, state.isActiveDevice else { cancelVolumeEditing(); return }
            if request.value == (lastVolumeSent ?? state.volume) { continue }
            let generation = volumeGeneration
            volumeDispatchedAt = volumeNow()
            lastVolumeSent = request.value
            BopifyLog.playback.debug("volume command dispatched")
            do { try await engine.setVolume(request.value) }
            catch {
                guard engineEpoch == epoch else { return }
                guard generation == volumeGeneration else { continue }
                if error as? PlayerError == .playbackSessionLost { reportSessionLoss(.commandFailed); return }
                lastVolumeSent = nil
                if volumeRequest == nil { volumeDraft = nil }
                commandNotice = String(localized: "command.unavailable", defaultValue: "That action is unavailable.")
                BopifyLog.playback.error("volume command failed")
            }
            if generation == volumeGeneration, !isEditingVolume, volumeRequest == nil, volumeDraft == state.volume {
                volumeDraft = nil
            }
        }
    }

    private func enqueue(_ name: String, requiresActive: Bool = false,
                         selection: QueueSelectionStatus? = nil,
                         _ operation: @escaping @Sendable () async throws -> Void) {
        guard isEngineReady, consumer != nil else { return }
        let epoch = engineEpoch
        let previous = pendingCommand
        let generation = commandGeneration
        pendingCommand = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled, generation == commandGeneration, engineEpoch == epoch, isEngineReady,
                  !requiresActive || state.isActiveDevice else { return }
            BopifyLog.playback.debug("command enqueued command=\(name, privacy: .public)")
            do { try await operation() }
            catch {
                guard generation == commandGeneration, engineEpoch == epoch else { return }
                if error as? PlayerError == .playbackSessionLost { reportSessionLoss(.commandFailed); return }
                if let selection {
                    guard queueSelection == selection else { return }
                    queueSelection = .failed
                }
                commandNotice = String(localized: "command.unavailable", defaultValue: "That action is unavailable.")
                BopifyLog.playback.error("command failed command=\(name, privacy: .public)")
            }
        }
    }

    private func freezeDisplayPosition() {
        if state.phase == .playing { frozenDisplayPositionMs = displayPositionMs(at: .now) }
    }

    /// A stopped device's last state, frozen: the record shows it, but the ring stops advancing.
    private func stalled(_ remote: RemotePlayback) -> RemotePlayback {
        RemotePlayback(deviceName: remote.deviceName, trackURI: remote.trackURI, track: remote.track,
                       isPlaying: false, positionMs: remote.positionMs, durationMs: remote.durationMs)
    }

    private func apply(_ event: PlaybackEvent) {
        let oldPhase = state.phase
        switch event {
        case var .queueChanged(queue):
            queue.next = queue.next.map { entry in
                QueueEntry(id: entry.id, uri: entry.uri,
                    target: entry.target.map { QueueTarget(generation: $0.generation, rawNextIndex: $0.rawNextIndex, engineEpoch: engineEpoch) },
                    track: entry.track, metadataFailed: entry.metadataFailed)
            }
            let cached = (state.queue?.previous ?? []) + (state.queue?.current.map { [$0] } ?? []) + (state.queue?.next ?? [])
            func retainingMetadata(_ entry: QueueEntry) -> QueueEntry {
                guard let old = cached.first(where: { $0.id == entry.id && $0.uri == entry.uri }) else { return entry }
                var result = entry
                result.track = old.track
                result.metadataFailed = old.metadataFailed
                return result
            }
            queue.previous = queue.previous.map(retainingMetadata)
            queue.current = queue.current.map(retainingMetadata)
            queue.next = queue.next.map(retainingMetadata)
            state.queue = queue
            commandNotice = nil
            if case let .pending(entryID, target) = queueSelection, queue.generation > target.generation {
                if queue.current?.id == entryID {
                    queueSelection = .confirmed(entryID: entryID, target: target)
                    BopifyLog.playback.debug("queue selection confirmed")
                } else {
                    queueSelection = .failed
                    commandNotice = String(localized: "queue.changed", defaultValue: "The queue changed. Choose the track again.")
                    BopifyLog.playback.debug("queue selection invalidated by replacement")
                }
            }
        case let .queueMetadata(generation, entryID, track):
            guard var queue = state.queue, queue.generation == generation else { return }
            func hydrated(_ entry: QueueEntry) -> QueueEntry {
                guard entry.id == entryID else { return entry }
                var result = entry
                result.track = track
                result.metadataFailed = track == nil
                return result
            }
            queue.previous = queue.previous.map(hydrated)
            queue.current = queue.current.map(hydrated)
            queue.next = queue.next.map(hydrated)
            state.queue = queue
        case let .shuffleChanged(enabled): state.shuffleEnabled = enabled
        case let .repeatChanged(mode): state.repeatMode = mode
        case let .commandRejected(reason):
            if case .pending = queueSelection { queueSelection = .failed }
            commandNotice = reason == "staleQueue"
                ? String(localized: "queue.changed", defaultValue: "The queue changed. Choose the track again.")
                : String(localized: "command.unavailable", defaultValue: "That action is unavailable.")
            BopifyLog.playback.debug("player command rejected")
        case let .trackChanged(track):
            frozenDisplayPositionMs = nil
            positionUpdatedAt = .now
            BopifyLog.playback.debug("track changed title=\(track.title, privacy: .private)")
            state.currentTrack = track
            state.durationMs = track.durationMs
            state.positionMs = 0
            state.canNext = true
            state.canPrevious = true
            state.canSeek = true
        case let .playing(position):
            lastConfirmedPlaying = true
            if !managedAttachment { isEngineReady = true }
            frozenDisplayPositionMs = nil
            positionUpdatedAt = .now
            state.phase = .playing; state.positionMs = position
            state.isActiveDevice = true
            state.remote = nil; state.staleRemote = nil
        case let .paused(position):
            lastConfirmedPlaying = false
            if !managedAttachment { isEngineReady = true }
            frozenDisplayPositionMs = nil
            positionUpdatedAt = .now
            state.phase = .paused; state.positionMs = position
            state.isActiveDevice = true
            state.remote = nil; state.staleRemote = nil
        case let .seeked(position), let .positionCorrection(position):
            frozenDisplayPositionMs = nil
            positionUpdatedAt = .now
            state.positionMs = position
        case let .volumeChanged(volume):
            state.volume = volume
            lastVolumeSent = volume
            if !isEditingVolume, volumeRequest == nil, volumeTask == nil || volumeDraft == volume { volumeDraft = nil }
            if volume.isFinite, volume > 0 { lastPositiveVolume = min(1, volume) }
        case .loading:
            // Keep metadata and the displayed position until the engine supplies new values.
            freezeDisplayPosition()
            state.phase = .loading
        case .endOfTrack:
            lastConfirmedPlaying = false
            frozenDisplayPositionMs = nil
            state.phase = .ended; state.positionMs = state.durationMs
        case let .activeDeviceChanged(isActive):
            state.isActiveDevice = isActive
            if !isActive {
                lastConfirmedPlaying = false
                cancelVolumeEditing()
                if case .pending = queueSelection { queueSelection = .failed }
                freezeDisplayPosition()
                state.phase = .idle
            } else {
                // Always nil while active: a mirror from just before the takeover must not linger.
                state.remote = nil
                state.staleRemote = nil
            }
        case let .recoveryIdentity(identity): recoveryIdentity = identity
        case let .connectionReady(outcome): setConnectionReady(outcome)
        case let .sessionLost(reason): reportSessionLoss(reason)
        case let .failed(error):
            if error == .playbackSessionLost && !reportedLoss { reportSessionLoss(.legacy); return }
            freezeDisplayPosition()
            state.phase = .error(error)
            let description = String(describing: error)
            BopifyLog.playback.error("playback failed error=\(description, privacy: .public)")
            if error == .playbackSessionLost { state.isActiveDevice = false; cancelVolumeEditing() }
            // A live mirror must stop advancing under the error, same as a device that stopped.
            if let remote = state.remote {
                state.staleRemote = stalled(remote)
                state.remote = nil
            }
        case let .startupResolved(outcome):
            state.startup = .resolved(outcome)
            let kind = switch outcome {
            case .restored: "restored"
            case .likedSongs: "likedSongs"
            case .remote: "remote"
            case .nothing: "nothing"
            }
            BopifyLog.playback.info("startup resolved outcome=\(kind, privacy: .public)")
        case let .remotePlayback(remote):
            // A lookup still in flight when Bopify took over must not bring the mirror back.
            guard !state.isActiveDevice else { break }
            if remote == nil, let last = state.remote {
                state.staleRemote = stalled(last)
            }
            state.remote = remote
            remoteUpdatedAt = .now
            BopifyLog.playback.debug("remote playback present=\(remote != nil, privacy: .public)")
        }
        if state.phase != oldPhase {
            let old = String(describing: oldPhase)
            let new = String(describing: state.phase)
            BopifyLog.playback.debug("phase transition old=\(old, privacy: .public) new=\(new, privacy: .public)")
        }
    }
}
