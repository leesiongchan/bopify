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
    }

    public func togglePlayPause() {
        let shouldPause = state.phase == .playing
        Task { [engine] in
            // A failure is reported by the engine as an event; nothing is
            // assumed here about whether the command took effect.
            if shouldPause {
                do { try await engine.pause() }
                catch {
                    let description = String(describing: error)
                    BopifyLog.playback.error("command failed command=pause error=\(description, privacy: .public)")
                }
            } else {
                do { try await engine.resume() }
                catch {
                    let description = String(describing: error)
                    BopifyLog.playback.error("command failed command=resume error=\(description, privacy: .public)")
                }
            }
        }
    }

    public func next() {
        Task { [engine] in
            do { try await engine.next() }
            catch {
                let description = String(describing: error)
                BopifyLog.playback.error("command failed command=next error=\(description, privacy: .public)")
            }
        }
    }

    public func previous() {
        Task { [engine] in
            do { try await engine.previous() }
            catch {
                let description = String(describing: error)
                BopifyLog.playback.error("command failed command=previous error=\(description, privacy: .public)")
            }
        }
    }

    public func activate() {
        Task { [engine] in
            do { try await engine.activate() }
            catch {
                let description = String(describing: error)
                BopifyLog.playback.error("command failed command=activate error=\(description, privacy: .public)")
            }
        }
    }

    /// Lets the UI start playback from a known context URI directly, in case
    /// Spotify Connect handoff to this device does not work.
    public func load(_ request: PlayRequest) {
        Task { [engine] in
            do { try await engine.load(request) }
            catch {
                let description = String(describing: error)
                BopifyLog.playback.error("command failed command=load error=\(description, privacy: .public)")
            }
        }
    }

    private func apply(_ event: PlaybackEvent) {
        let oldPhase = state.phase
        switch event {
        case let .queueChanged(queue):
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
            commandNotice = reason == "staleQueue" ? "The queue changed. Choose the track again." : "That action is unavailable."
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
