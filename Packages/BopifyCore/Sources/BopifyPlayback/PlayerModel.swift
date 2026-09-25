import Foundation
import Observation
import os
import BopifyDomain

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
    public private(set) var state = PlaybackState()
    public private(set) var commandNotice: String?
    private(set) var positionUpdatedAt = Date.now

    @ObservationIgnored private let engine: any PlaybackEngine
    @ObservationIgnored private var consumer: Task<Void, Never>?
    @ObservationIgnored private var pendingCommand: Task<Void, Never>?
    @ObservationIgnored private var commandGeneration: UInt64 = 0

    public init(engine: any PlaybackEngine) { self.engine = engine }

    /// Interpolate for display without replacing the engine's authoritative position.
    public func displayPositionMs(at date: Date) -> Int64 {
        let elapsed = state.phase == .playing ? max(0, date.timeIntervalSince(positionUpdatedAt)) * 1000 : 0
        let position = min(Double(max(0, state.durationMs)), max(0, Double(state.positionMs) + elapsed))
        return Int64(position)
    }

    /// One consumer for the model's lifetime. A per-view .task would
    /// resubscribe whenever view identity changed.
    public func start() {
        guard consumer == nil else { return }
        BopifyLog.playback.info("player model starting")
        consumer = Task { [engine] in
            for await event in engine.events {
                self.apply(event)
            }
        }
    }

    public func stop() {
        guard consumer != nil else { return }
        BopifyLog.playback.info("player model stopping")
        consumer?.cancel()
        consumer = nil
        commandGeneration &+= 1
        pendingCommand?.cancel()
        pendingCommand = nil
    }

    public func togglePlayPause() {
        guard state.isActiveDevice else { return }
        let shouldPause = state.phase == .playing
        enqueue(shouldPause ? "pause" : "resume", requiresActive: true) { [engine] in
            if shouldPause { try await engine.pause() } else { try await engine.resume() }
        }
    }

    public func next() {
        guard state.isActiveDevice, state.canNext else { return }
        enqueue("next", requiresActive: true) { [engine] in try await engine.next() }
    }

    public func previous() {
        guard state.isActiveDevice, state.canPrevious else { return }
        enqueue("previous", requiresActive: true) { [engine] in try await engine.previous() }
    }

    public func activate() {
        enqueue("activate") { [engine] in try await engine.activate() }
    }

    public func load(_ request: PlayRequest) {
        enqueue("load") { [engine] in try await engine.load(request) }
    }

    public func seek(to milliseconds: Int64) {
        guard state.isActiveDevice, state.canSeek, state.durationMs > 0 else { return }
        let target = min(max(0, milliseconds), state.durationMs)
        enqueue("seek", requiresActive: true) { [engine] in try await engine.seek(to: target) }
    }

    public func seek(by milliseconds: Int64) {
        let (target, overflow) = displayPositionMs(at: .now).addingReportingOverflow(milliseconds)
        seek(to: overflow ? (milliseconds > 0 ? state.durationMs : 0) : target)
    }

    public func selectQueueEntry(_ target: QueueTarget) {
        guard state.isActiveDevice else { return }
        guard state.queue?.generation == target.generation,
              state.queue?.next.contains(where: { $0.target == target }) == true else {
            commandNotice = String(localized: "queue.changed", defaultValue: "The queue changed. Choose the track again.")
            return
        }
        enqueue("selectQueue", requiresActive: true) { [engine] in try await engine.selectQueueEntry(target) }
    }

    public func setShuffle(_ enabled: Bool) {
        guard state.isActiveDevice else { return }
        enqueue("setShuffle", requiresActive: true) { [engine] in try await engine.setShuffle(enabled) }
    }

    public func setRepeat(_ mode: RepeatMode) {
        guard state.isActiveDevice else { return }
        enqueue("setRepeat", requiresActive: true) { [engine] in try await engine.setRepeat(mode) }
    }

    public func setVolume(_ value: Double) {
        guard state.isActiveDevice, value.isFinite else { return }
        let volume = max(0, min(1, value))
        enqueue("setVolume", requiresActive: true) { [engine] in try await engine.setVolume(volume) }
    }

    private func enqueue(_ name: String, requiresActive: Bool = false,
                         _ operation: @escaping @Sendable () async throws -> Void) {
        guard consumer != nil else { return }
        let previous = pendingCommand
        let generation = commandGeneration
        pendingCommand = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled, generation == commandGeneration,
                  !requiresActive || state.isActiveDevice else { return }
            BopifyLog.playback.debug("command enqueued command=\(name, privacy: .public)")
            do { try await operation() }
            catch {
                guard generation == commandGeneration else { return }
                commandNotice = String(localized: "command.unavailable", defaultValue: "That action is unavailable.")
                BopifyLog.playback.error("command failed command=\(name, privacy: .public)")
            }
        }
    }

    private func apply(_ event: PlaybackEvent) {
        let oldPhase = state.phase
        switch event {
        case var .queueChanged(queue):
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
            commandNotice = reason == "staleQueue"
                ? String(localized: "queue.changed", defaultValue: "The queue changed. Choose the track again.")
                : String(localized: "command.unavailable", defaultValue: "That action is unavailable.")
            BopifyLog.playback.debug("player command rejected")
        case let .trackChanged(track):
            positionUpdatedAt = .now
            BopifyLog.playback.debug("track changed title=\(track.title, privacy: .private)")
            state.currentTrack = track
            state.durationMs = track.durationMs
            state.positionMs = 0
            state.canNext = true
            state.canPrevious = true
            state.canSeek = true
        case let .playing(position):
            positionUpdatedAt = .now
            state.phase = .playing; state.positionMs = position
            state.isActiveDevice = true
        case let .paused(position):
            positionUpdatedAt = .now
            state.phase = .paused; state.positionMs = position
            state.isActiveDevice = true
        case let .seeked(position), let .positionCorrection(position):
            positionUpdatedAt = .now
            state.positionMs = position
        case let .volumeChanged(volume):
            state.volume = volume
        case .loading:
            // Metadata is preserved deliberately (PRD PLAY-07).
            state.phase = .loading
        case .endOfTrack:
            state.phase = .ended; state.positionMs = state.durationMs
        case let .activeDeviceChanged(isActive):
            state.isActiveDevice = isActive
            if !isActive { state.phase = .idle }
        case let .failed(error):
            state.phase = .error(error)
            let description = String(describing: error)
            BopifyLog.playback.error("playback failed error=\(description, privacy: .public)")
            if error == .playbackSessionLost { state.isActiveDevice = false }
        }
        if state.phase != oldPhase {
            let old = String(describing: oldPhase)
            let new = String(describing: state.phase)
            BopifyLog.playback.debug("phase transition old=\(old, privacy: .public) new=\(new, privacy: .public)")
        }
    }
}
