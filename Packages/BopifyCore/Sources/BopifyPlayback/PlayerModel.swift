import Foundation
import Observation
import os
import BopifyDomain

/// Folds engine events into observable state on the main actor.
///
/// Deliberately not an actor: under SE-0461 a nonisolated async function
/// runs on the caller's actor, so an actor here would drag blocking FFI
/// work onto the main thread. Blocking work goes through @concurrent instead.
@MainActor
@Observable
public final class PlayerModel {
    public private(set) var state = PlaybackState()

    @ObservationIgnored private let engine: any PlaybackEngine
    @ObservationIgnored private var consumer: Task<Void, Never>?

    public init(engine: any PlaybackEngine) { self.engine = engine }

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
        case let .trackChanged(track):
            BopifyLog.playback.debug("track changed title=\(track.title, privacy: .private)")
            state.currentTrack = track
            state.durationMs = track.durationMs
            state.positionMs = 0
            state.canNext = true
            state.canPrevious = true
            state.canSeek = true
        case let .playing(position):
            state.phase = .playing; state.positionMs = position
            state.isActiveDevice = true
        case let .paused(position):
            state.phase = .paused; state.positionMs = position
            state.isActiveDevice = true
        case let .seeked(position), let .positionCorrection(position):
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
