import Foundation
import Observation
import BopifyDomain
import BopifyPlayback
import os

@MainActor @Observable
final class LiveLyricRibbonSession {
    let model: LyricRibbonModel
    var isVisible: Bool { model.isVisible }
    @ObservationIgnored private let player: PlayerModel
    @ObservationIgnored private let requestLyrics: @MainActor (SpotifyURI, UInt64) async throws -> TrackLyrics
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var input: Input?
    @ObservationIgnored private var request: Task<Void, Never>?
    @ObservationIgnored private var clock: Task<Void, Never>?
    @ObservationIgnored private var requestGeneration: UInt64 = 0
    @ObservationIgnored private var observationGeneration: UInt64 = 0
    @ObservationIgnored private var clockGeneration: UInt64 = 0
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private lazy var controller = LyricRibbonWindowController(model: model, defaults: defaults,
        onHide: { [weak self] in self?.hide() })

    private struct Input: Equatable {
        let epoch: UInt64
        let playbackRevision: UInt64
        let queueEntryID: String?
        let trackURI: SpotifyURI
    }

    private enum State {
        case local(Input, LyricPlaybackSnapshot)
        case idle(LyricIdleReason, LyricPlaybackSnapshot)
    }

    init(player: PlayerModel,
         requestLyrics: @escaping @MainActor (SpotifyURI, UInt64) async throws -> TrackLyrics,
         defaults: UserDefaults = .standard, now: @escaping @MainActor () -> Date = { .now },
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.player = player
        self.requestLyrics = requestLyrics
        self.defaults = defaults
        self.now = now
        self.sleep = sleep
        model = LyricRibbonModel(snapshot: LyricPlaybackSnapshot(sessionID: "none", occurrenceID: "none",
            recordingID: "", title: "Lyrics", artist: "", positionMs: 0, durationMs: 0, isPlaying: false, seekRevision: 0))
        model.setIdle(.noTrack)
    }

    func show() {
        guard !stopped, !isVisible else { return }
        model.show()
        observationGeneration &+= 1
        observe()
        controller.show()
    }

    func hide() {
        observationGeneration &+= 1
        cancelRequest()
        stopClock()
        input = nil
        controller.hide()
        model.setIdle(.noTrack)
    }

    func focusForReading() {
        guard !stopped else { return }
        if !isVisible { show() }
        controller.focusForReading()
    }

    func shutdown() {
        guard !stopped else { return }
        stopped = true
        hide()
    }

    private func observe() {
        guard !stopped, isVisible else { return }
        let generation = observationGeneration
        // Track only player reads; observing our own presentation writes would reschedule itself.
        let state = withObservationTracking { readState() } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.observationGeneration == generation else { return }
                self.observe()
            }
        }
        apply(state)
    }

    private func readState() -> State {
        let state = player.state
        let neutral = LyricPlaybackSnapshot(sessionID: String(player.engineEpoch), occurrenceID: "none",
            recordingID: "", title: "Lyrics", artist: "", positionMs: 0, durationMs: 0,
            isPlaying: false, seekRevision: player.seekRevision)
        func idle(_ reason: LyricIdleReason) -> State { .idle(reason, neutral) }
        guard player.isEngineReady else { return idle(.connecting) }
        if state.mirror != nil { return idle(.otherDevice) }
        guard let track = state.currentTrack else { return idle(.noTrack) }
        guard state.isActiveDevice else { return idle(.otherDevice) }
        guard track.uri.kind == .track else { return idle(.unsupported) }
        if let current = state.queue?.current {
            guard let uri = current.uri, uri.kind == .track else { return idle(.unsupported) }
            guard uri == track.uri else { return idle(.loadingTrack) }
        }
        switch state.phase {
        case .loading, .buffering: return idle(.loadingTrack)
        case .idle: return idle(.noTrack)
        case .error: return idle(.playbackUnavailable)
        case .playing, .paused, .ended: break
        }
        let input = Input(epoch: player.engineEpoch, playbackRevision: player.playbackRevision,
                          queueEntryID: state.queue?.current?.id, trackURI: track.uri)
        let snapshot = LyricPlaybackSnapshot(sessionID: String(input.epoch),
            occurrenceID: "\(input.playbackRevision):\(input.queueEntryID ?? "")", recordingID: track.uri.rawValue,
            title: track.title, artist: track.artists.map(\.name).joined(separator: ", "),
            positionMs: player.displayPositionMs(at: now()), durationMs: player.displayDurationMs,
            isPlaying: player.isPositionAdvancing, seekRevision: player.seekRevision)
        return .local(input, snapshot)
    }

    private func apply(_ state: State) {
        switch state {
        case let .idle(reason, snapshot):
            if input != nil { cancelRequest(); input = nil }
            stopClock()
            model.update(snapshot)
            if model.content != .idle(reason) {
                model.setIdle(reason)
                controller.refreshLayout(textScale: 1)
            }
        case let .local(next, snapshot):
            model.update(snapshot)
            if input != next {
                cancelRequest()
                input = next
                let token = model.beginLoad()
                controller.refreshLayout(textScale: 1)
                load(next, token: token)
            }
            if snapshot.isPlaying { startClock() } else { stopClock() }
        }
    }

    private func load(_ input: Input, token: LyricLoadToken) {
        let generation = requestGeneration
        let fetch = requestLyrics
        BopifyLog.playback.debug("live lyrics request started generation=\(generation, privacy: .public)")
        request = Task { [weak self] in
            let result: Result<TrackLyrics, any Error>
            do { result = .success(try await fetch(input.trackURI, input.epoch)) }
            catch { result = .failure(error) }
            guard let self else { return }
            defer { if self.requestGeneration == generation { self.request = nil } }
            guard !Task.isCancelled, !self.stopped, self.isVisible, self.requestGeneration == generation,
                  case let .local(current, snapshot) = self.readState(), current == input else { return }
            self.model.update(snapshot)
            do {
                let lyrics = try result.get()
                guard lyrics.trackURI == input.trackURI else { throw LyricFailure.unavailable }
                let presentation = try LyricPresentation(lyrics: lyrics)
                self.model.completeLoad(presentation.content, token: token, source: presentation.source)
                BopifyLog.playback.debug("live lyrics request completed")
            } catch is CancellationError { return }
            catch {
                self.model.completeLoad(error as? LyricFailure == .noLyrics ? .noMatch : .failure, token: token)
                BopifyLog.playback.debug("live lyrics request unavailable")
            }
            self.controller.refreshLayout(textScale: 1)
        }
    }

    private func cancelRequest() {
        requestGeneration &+= 1
        request?.cancel()
        request = nil
    }

    private func startClock() {
        guard clock == nil else { return }
        let generation = clockGeneration
        let sleep = sleep
        clock = Task { [weak self] in
            while !Task.isCancelled {
                do { try await sleep(.milliseconds(100)) } catch { return }
                guard let self, !Task.isCancelled, self.clockGeneration == generation,
                      !self.stopped, self.isVisible else { return }
                self.apply(self.readState())
            }
        }
    }

    private func stopClock() {
        clockGeneration &+= 1
        clock?.cancel()
        clock = nil
    }
}
