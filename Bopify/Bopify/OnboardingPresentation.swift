import Foundation
import Observation
import os
import BopifyDomain

/// Owns visual acknowledgements independently of authentication and audio readiness.
@MainActor @Observable
final class OnboardingPresentation {
    enum Phase: Equatable { case idle, libraryConnected, completing, handoff }
    private(set) var phase: Phase = .idle
    private(set) var isArmed = false
    private(set) var completionID: UUID?
    var onHandoff: (() -> Void)?
    @ObservationIgnored private let sleep: @MainActor (Duration) async throws -> Void
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var playbackReady = false
    @ObservationIgnored private var isAnimationPresentationVisible = false
    @ObservationIgnored private var hasSettledCompletion = false
    @ObservationIgnored private var isWaitingForAnimation = false

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

    func playbackReadinessChanged(_ ready: Bool) {
        playbackReady = ready
        guard isArmed else { return }
        if !ready {
            if phase == .completing || phase == .handoff {
                invalidateWork()
                phase = .idle
                completionID = nil
                hasSettledCompletion = false
                isWaitingForAnimation = false
            }
        } else if phase == .idle {
            complete()
        } else if phase == .completing,
                  isWaitingForAnimation != shouldWaitForAnimation {
            scheduleCompletion()
        }
    }

    func setAnimationPresentationVisible(_ visible: Bool) {
        guard visible != isAnimationPresentationVisible else { return }
        isAnimationPresentationVisible = visible
        if phase == .completing, isWaitingForAnimation != shouldWaitForAnimation {
            scheduleCompletion()
        } else if phase == .handoff, !visible, let id = completionID {
            handoffSettled(for: id)
        }
    }

    func animationSettled(for id: UUID) {
        guard phase == .completing, completionID == id, !hasSettledCompletion else { return }
        hasSettledCompletion = true
        BopifyLog.playback.info("onboarding completion animation settled")
        if isWaitingForAnimation { scheduleCompletion() }
    }

    func handoffSettled(for id: UUID) {
        guard phase == .handoff, completionID == id, isArmed, playbackReady else { return }
        invalidateWork()
        isArmed = false
        phase = .idle
        completionID = nil
        hasSettledCompletion = false
        isWaitingForAnimation = false
        BopifyLog.playback.info("onboarding player handoff completed")
    }

    private func complete() {
        guard isArmed, playbackReady, phase == .idle else { return }
        BopifyLog.playback.info("onboarding completion confirmation started")
        phase = .completing
        completionID = UUID()
        hasSettledCompletion = false
        scheduleCompletion()
    }

    private var shouldWaitForAnimation: Bool {
        isAnimationPresentationVisible && !hasSettledCompletion
    }

    private func scheduleCompletion() {
        guard phase == .completing, isArmed, playbackReady, let id = completionID else { return }
        invalidateWork()
        isWaitingForAnimation = shouldWaitForAnimation
        let mine = generation, sleep = self.sleep
        if isWaitingForAnimation {
            work = Task { [weak self] in
                do { try await sleep(StartupAnimationTiming.maximumCompletionWait) } catch { return }
                guard let self, self.generation == mine, self.completionID == id,
                      self.isArmed, self.playbackReady, self.phase == .completing, !Task.isCancelled else { return }
                BopifyLog.playback.notice("onboarding completion animation deadline exceeded")
                self.work = nil
                self.hasSettledCompletion = true
                self.scheduleCompletion()
            }
            return
        }
        let confirmation: Duration = .milliseconds(350)
        work = Task { [weak self] in
            do {
                try await sleep(confirmation)
                guard let self, self.generation == mine, self.completionID == id,
                      self.isArmed, self.playbackReady, !Task.isCancelled else { return }
                self.phase = .handoff
                BopifyLog.playback.info("onboarding player handoff started")
                // Hand the work slot to the next phase before invoking a callback
                // that may synchronously finish or cancel this setup.
                self.work = nil
                self.scheduleHandoffCompletion()
                self.onHandoff?()
            } catch {}
        }
    }

    private func scheduleHandoffCompletion() {
        guard phase == .handoff, isArmed, playbackReady, let id = completionID else { return }
        invalidateWork()
        let waitsForAnimation = isAnimationPresentationVisible
        let delay: Duration = waitsForAnimation ? StartupAnimationTiming.maximumCompletionWait
            : .milliseconds(650)
        let mine = generation, sleep = self.sleep
        work = Task { [weak self] in
            do { try await sleep(delay) } catch { return }
            guard let self, self.generation == mine, self.completionID == id,
                  self.phase == .handoff, self.isArmed, self.playbackReady, !Task.isCancelled else { return }
            self.work = nil
            if waitsForAnimation { BopifyLog.playback.notice("onboarding player handoff animation deadline exceeded") }
            self.handoffSettled(for: id)
        }
    }

    func cancel() {
        invalidateWork()
        isArmed = false
        playbackReady = false
        phase = .idle
        completionID = nil
        hasSettledCompletion = false
        isWaitingForAnimation = false
    }

    private func invalidateWork() {
        generation &+= 1
        work?.cancel()
        work = nil
    }
}
