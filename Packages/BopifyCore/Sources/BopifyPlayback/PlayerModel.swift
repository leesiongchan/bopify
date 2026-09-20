import Foundation
import Observation
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
        consumer = Task { [engine] in
            for await event in engine.events {
                self.apply(event)
            }
        }
    }

    public func stop() {
        consumer?.cancel()
        consumer = nil
    }

    public func togglePlayPause() {
        let shouldPause = state.phase == .playing
        Task { [engine] in
            // A failure is reported by the engine as an event; nothing is
            // assumed here about whether the command took effect.
            if shouldPause {
                try? await engine.pause()
            } else {
                try? await engine.resume()
            }
        }
    }

    public func next() { Task { [engine] in try? await engine.next() } }
    public func previous() { Task { [engine] in try? await engine.previous() } }
    public func activate() { Task { [engine] in try? await engine.activate() } }

    /// Lets the UI start playback from a known context URI directly, in case
    /// Spotify Connect handoff to this device does not work.
    public func load(_ request: PlayRequest) { Task { [engine] in try? await engine.load(request) } }

    private func apply(_ event: PlaybackEvent) {
        switch event {
        case let .trackChanged(track):
            state.currentTrack = track
            state.durationMs = track.durationMs
            state.positionMs = 0
            state.canNext = true
            state.canPrevious = true
            state.canSeek = true
            state.error = nil
        case let .playing(position):
            state.phase = .playing; state.positionMs = position
            state.isActiveDevice = true; state.error = nil
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
            state.phase = .error; state.error = error
            if error == .playbackSessionLost { state.isActiveDevice = false }
        }
    }
}
