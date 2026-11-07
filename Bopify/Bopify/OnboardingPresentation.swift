import Foundation
import Observation

/// Owns visual acknowledgements independently of authentication and audio readiness.
@MainActor @Observable
final class OnboardingPresentation {
    enum Phase: Equatable { case idle, libraryConnected, completing, handoff }
    private(set) var phase: Phase = .idle
    private(set) var isArmed = false
    var onHandoff: (() -> Void)?
    @ObservationIgnored private let sleep: @MainActor (Duration) async throws -> Void
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var playbackReady = false
    @ObservationIgnored private var reduceMotion = false

    init(sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    func begin() {
        cancel()
        isArmed = true
    }

    func confirmLibraryConnection() {
        guard isArmed, phase == .idle else { return }
        phase = .libraryConnected
        let mine = generation, sleep = self.sleep
        work = Task { [weak self] in
            do { try await sleep(.milliseconds(450)) } catch { return }
            guard let self, self.generation == mine, self.isArmed, !Task.isCancelled else { return }
            self.work = nil
            self.phase = .idle
            if self.playbackReady { self.complete() }
        }
    }

    func playbackReadinessChanged(_ ready: Bool, reduceMotion: Bool = false) {
        playbackReady = ready
        self.reduceMotion = reduceMotion
        guard isArmed else { return }
        if !ready {
            if phase == .completing || phase == .handoff {
                invalidateWork()
                phase = .idle
            }
        } else if phase == .idle {
            complete()
        }
    }

    private func complete() {
        guard isArmed, playbackReady, phase == .idle else { return }
        phase = .completing
        let mine = generation, sleep = self.sleep
        let confirmation: Duration = reduceMotion ? .milliseconds(180) : .milliseconds(350)
        let handoff: Duration = reduceMotion ? .milliseconds(150) : .milliseconds(650)
        work = Task { [weak self] in
            do {
                try await sleep(confirmation)
                guard let self, self.generation == mine, self.isArmed, self.playbackReady, !Task.isCancelled else { return }
                self.phase = .handoff
                self.onHandoff?()
                guard self.generation == mine, !Task.isCancelled else { return }
                try await sleep(handoff)
                guard self.generation == mine, self.isArmed, self.playbackReady, !Task.isCancelled else { return }
                self.isArmed = false
                self.phase = .idle
                self.work = nil
            } catch {}
        }
    }

    func cancel() {
        invalidateWork()
        isArmed = false
        playbackReady = false
        phase = .idle
    }

    private func invalidateWork() {
        generation &+= 1
        work?.cancel()
        work = nil
    }
}
