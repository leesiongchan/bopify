import Testing
import Foundation

@MainActor @Suite("Onboarding presentation", .serialized)
struct OnboardingPresentationTests {
    private func startVisibleHandoff(_ presentation: OnboardingPresentation, clock: LiveLyricTestClock) async throws -> UUID {
        presentation.setAnimationPresentationVisible(true)
        presentation.begin()
        presentation.playbackReadinessChanged(true)
        let id = try #require(presentation.completionID)
        try await liveLyricEventually { clock.pendingDelays.count == 1 }
        presentation.animationSettled(for: id)
        try await liveLyricEventually { clock.pendingDelays.contains(.milliseconds(350)) }
        clock.advance(by: .milliseconds(350))
        try await liveLyricEventually { presentation.phase == .handoff && clock.pendingDelays.count == 1 }
        return id
    }

    @Test func visibleHandoffDoesNotDisappearAfterTheOldFixedDelay() async throws {
        let clock = LiveLyricTestClock()
        let presentation = OnboardingPresentation(sleep: { try await clock.sleep(for: $0) })
        defer { presentation.cancel() }
        _ = try await startVisibleHandoff(presentation, clock: clock)
        clock.advance(by: .milliseconds(650))
        for _ in 0..<30 { await Task.yield() }
        #expect(presentation.phase == .handoff && presentation.isArmed)
    }

    @Test func matchingWindowAnimationCompletionFinishesTheHandoff() async throws {
        let clock = LiveLyricTestClock()
        let presentation = OnboardingPresentation(sleep: { try await clock.sleep(for: $0) })
        defer { presentation.cancel() }
        let id = try await startVisibleHandoff(presentation, clock: clock)
        presentation.handoffSettled(for: id)
        #expect(presentation.phase == .idle && !presentation.isArmed && presentation.completionID == nil)
        try await liveLyricEventually { clock.pendingDelays.isEmpty }
    }

    @Test func missingWindowAnimationCompletionHasABoundedFallback() async throws {
        let clock = LiveLyricTestClock()
        let presentation = OnboardingPresentation(sleep: { try await clock.sleep(for: $0) })
        defer { presentation.cancel() }
        _ = try await startVisibleHandoff(presentation, clock: clock)
        #expect(clock.pendingDelays == [StartupAnimationTiming.maximumCompletionWait])
        clock.advance(by: StartupAnimationTiming.maximumCompletionWait)
        try await liveLyricEventually { presentation.phase == .idle && !presentation.isArmed }
        #expect(presentation.completionID == nil)
    }

    @Test func hidingDuringHandoffDoesNotWaitForAnInvisibleWindowAnimation() async throws {
        let clock = LiveLyricTestClock()
        let presentation = OnboardingPresentation(sleep: { try await clock.sleep(for: $0) })
        defer { presentation.cancel() }
        let id = try await startVisibleHandoff(presentation, clock: clock)
        presentation.setAnimationPresentationVisible(false)
        #expect(presentation.phase == .idle && !presentation.isArmed)
        presentation.handoffSettled(for: id)
        try await liveLyricEventually { clock.pendingDelays.isEmpty }
    }

    @Test(arguments: ["newSetup", "readinessLoss", "cancel"])
    func staleWindowCompletionCannotReleaseAnotherSetup(interruption: String) async throws {
        let clock = LiveLyricTestClock()
        let presentation = OnboardingPresentation(sleep: { try await clock.sleep(for: $0) })
        defer { presentation.cancel() }
        let old = try await startVisibleHandoff(presentation, clock: clock)
        if interruption == "newSetup" {
            let current = try await startVisibleHandoff(presentation, clock: clock)
            #expect(current != old)
            presentation.handoffSettled(for: old)
            #expect(presentation.phase == .handoff && presentation.isArmed && presentation.completionID == current)
            presentation.handoffSettled(for: current)
            #expect(!presentation.isArmed)
        } else {
            if interruption == "readinessLoss" { presentation.playbackReadinessChanged(false) }
            else { presentation.cancel() }
            presentation.handoffSettled(for: old)
            #expect(presentation.phase == .idle && presentation.completionID == nil)
            #expect(presentation.isArmed == (interruption == "readinessLoss"))
        }
    }

    @Test func aSynchronousHandoffCallbackCannotLeaveALateCleanupTask() async throws {
        let clock = LiveLyricTestClock()
        let presentation = OnboardingPresentation(sleep: { try await clock.sleep(for: $0) })
        defer { presentation.cancel() }
        presentation.onHandoff = { [weak presentation] in
            if let id = presentation?.completionID { presentation?.handoffSettled(for: id) }
        }
        presentation.setAnimationPresentationVisible(true)
        presentation.begin()
        presentation.playbackReadinessChanged(true)
        let id = try #require(presentation.completionID)
        presentation.animationSettled(for: id)
        try await liveLyricEventually { clock.pendingDelays == [.milliseconds(350)] }
        clock.advance(by: .milliseconds(350))
        try await liveLyricEventually { presentation.phase == .idle && !presentation.isArmed && clock.pendingDelays.isEmpty }
    }

    @Test func visibleCompletionWaitsForTheFullRecordAnimationBeforeAcknowledging() async throws {
        let clock = LiveLyricTestClock()
        let presentation = OnboardingPresentation(sleep: { try await clock.sleep(for: $0) })
        defer { presentation.cancel() }
        presentation.setAnimationPresentationVisible(true)
        presentation.begin()
        presentation.playbackReadinessChanged(true)
        let id = try #require(presentation.completionID)
        try await liveLyricEventually { clock.pendingDelays.count == 1 }

        clock.advance(by: .seconds(1))
        for _ in 0..<30 { await Task.yield() }
        #expect(presentation.phase == .completing)

        presentation.animationSettled(for: id)
        try await liveLyricEventually { clock.pendingDelays.contains(.milliseconds(350)) }
        #expect(presentation.phase == .completing)
        clock.advance(by: .milliseconds(350))
        try await liveLyricEventually { presentation.phase == .handoff }
    }

    @Test func presentingTheRecordDuringConfirmationAddsTheAnimationGate() async throws {
        let clock = LiveLyricTestClock()
        let presentation = OnboardingPresentation(sleep: { try await clock.sleep(for: $0) })
        defer { presentation.cancel() }
        presentation.begin()
        presentation.playbackReadinessChanged(true)
        try await liveLyricEventually { clock.pendingDelays.contains(.milliseconds(350)) }
        presentation.setAnimationPresentationVisible(true)
        try await liveLyricEventually { clock.pendingDelays.contains(StartupAnimationTiming.maximumCompletionWait) }
        clock.advance(by: .seconds(1))
        for _ in 0..<30 { await Task.yield() }
        #expect(presentation.phase == .completing)
    }

    @Test func aPreviousRecordsCompletionCannotReleaseANewSetup() async throws {
        let clock = LiveLyricTestClock()
        let presentation = OnboardingPresentation(sleep: { try await clock.sleep(for: $0) })
        defer { presentation.cancel() }
        presentation.setAnimationPresentationVisible(true)
        presentation.begin()
        presentation.playbackReadinessChanged(true)
        let old = try #require(presentation.completionID)
        presentation.begin()
        presentation.playbackReadinessChanged(true)
        let current = try #require(presentation.completionID)
        #expect(old != current)
        presentation.animationSettled(for: old)
        try await liveLyricEventually { clock.pendingDelays.contains(StartupAnimationTiming.maximumCompletionWait) }
        clock.advance(by: .seconds(1))
        for _ in 0..<30 { await Task.yield() }
        #expect(presentation.phase == .completing)
        presentation.animationSettled(for: current)
        try await liveLyricEventually { clock.pendingDelays.contains(.milliseconds(350)) }
    }

    @Test func hidingTheRecordDoesNotLeaveSetupWaitingForAnInvisibleAnimation() async throws {
        let clock = LiveLyricTestClock()
        let presentation = OnboardingPresentation(sleep: { try await clock.sleep(for: $0) })
        defer { presentation.cancel() }
        presentation.setAnimationPresentationVisible(true)
        presentation.begin()
        presentation.playbackReadinessChanged(true)
        try await liveLyricEventually { clock.pendingDelays.contains(StartupAnimationTiming.maximumCompletionWait) }
        presentation.setAnimationPresentationVisible(false)
        try await liveLyricEventually { clock.pendingDelays.contains(.milliseconds(350)) }
        clock.advance(by: .milliseconds(350))
        try await liveLyricEventually { presentation.phase == .handoff }
    }

    @Test func aMissingAnimationCallbackHasABoundedRecovery() async throws {
        let clock = LiveLyricTestClock()
        let presentation = OnboardingPresentation(sleep: { try await clock.sleep(for: $0) })
        defer { presentation.cancel() }
        presentation.setAnimationPresentationVisible(true)
        presentation.begin()
        presentation.playbackReadinessChanged(true)
        try await liveLyricEventually { clock.pendingDelays.contains(StartupAnimationTiming.maximumCompletionWait) }
        clock.advance(by: StartupAnimationTiming.maximumCompletionWait)
        try await liveLyricEventually { clock.pendingDelays.contains(.milliseconds(350)) }
        clock.advance(by: .milliseconds(350))
        try await liveLyricEventually { presentation.phase == .handoff }
    }

    @Test func returningReadinessDoesNotReplayCompletion() {
        let presentation = OnboardingPresentation()
        presentation.playbackReadinessChanged(true)
        #expect(presentation.phase == .idle)
        #expect(!presentation.isArmed)
    }

    @Test func completionStartsOnlyAfterActualReadiness() {
        let presentation = OnboardingPresentation()
        defer { presentation.cancel() }
        presentation.begin()
        presentation.playbackReadinessChanged(false)
        #expect(presentation.phase == .idle)
        presentation.playbackReadinessChanged(true)
        #expect(presentation.phase == .completing)
    }

    @Test func libraryAcknowledgementPrecedesPendingCompletion() async throws {
        let clock = LiveLyricTestClock()
        let presentation = OnboardingPresentation(sleep: { try await clock.sleep(for: $0) })
        defer { presentation.cancel() }
        presentation.begin()
        presentation.confirmLibraryConnection()
        try #require(presentation.phase == .libraryConnected)
        presentation.playbackReadinessChanged(true)
        #expect(presentation.phase == .libraryConnected)
        try await liveLyricEventually { clock.pendingDelays.count == 1 }
        clock.advance(by: .seconds(1))
        try await liveLyricEventually { presentation.phase == .completing }
    }

    @Test func repeatedReadinessProducesOneAutomaticHandoff() async throws {
        let clock = LiveLyricTestClock()
        let presentation = OnboardingPresentation(sleep: { try await clock.sleep(for: $0) })
        defer { presentation.cancel() }
        var handoffs = 0
        presentation.onHandoff = { handoffs += 1 }
        presentation.begin()
        for _ in 0..<10 { presentation.playbackReadinessChanged(true) }
        try #require(presentation.phase == .completing)
        try await liveLyricEventually { clock.pendingDelays.count == 1 }
        #expect(clock.pendingDelays.allSatisfy { $0 <= .seconds(1) })
        clock.advance(by: .seconds(1))
        try await liveLyricEventually { presentation.phase == .handoff && clock.pendingDelays.count == 1 }
        #expect(handoffs == 1)
        clock.advance(by: .seconds(1))
        try await liveLyricEventually { presentation.phase == .idle }
        #expect(!presentation.isArmed)
        presentation.playbackReadinessChanged(true)
        #expect(presentation.phase == .idle && handoffs == 1)
    }

    @Test func readinessLossCancelsConfirmationWithoutDiscardingSetup() async throws {
        let clock = LiveLyricTestClock()
        let presentation = OnboardingPresentation(sleep: { try await clock.sleep(for: $0) })
        defer { presentation.cancel() }
        var handoffs = 0
        presentation.onHandoff = { handoffs += 1 }
        presentation.begin()
        presentation.playbackReadinessChanged(true)
        try #require(presentation.phase == .completing)
        try await liveLyricEventually { !clock.pendingDelays.isEmpty }
        presentation.playbackReadinessChanged(false)
        try await liveLyricEventually { clock.pendingDelays.isEmpty }
        clock.advance(by: .seconds(2))
        #expect(presentation.phase == .idle && presentation.isArmed && handoffs == 0)
        presentation.playbackReadinessChanged(true)
        #expect(presentation.phase == .completing)
    }

    @Test func cancellationAndSupersedingSetupRejectLateAnimations() async throws {
        let clock = LiveLyricTestClock()
        let presentation = OnboardingPresentation(sleep: { try await clock.sleep(for: $0) })
        defer { presentation.cancel() }
        var handoffs = 0
        presentation.onHandoff = { handoffs += 1 }
        presentation.begin()
        presentation.playbackReadinessChanged(true)
        try #require(presentation.phase == .completing)
        try await liveLyricEventually { clock.pendingDelays.count == 1 }
        presentation.cancel()
        try await liveLyricEventually { clock.pendingDelays.isEmpty }
        presentation.begin()
        presentation.confirmLibraryConnection()
        try await liveLyricEventually { clock.pendingDelays.count == 1 }
        clock.advance(by: .seconds(1))
        try await liveLyricEventually { presentation.phase == .idle }
        #expect(presentation.isArmed && handoffs == 0)
        presentation.cancel()
        clock.advance(by: .seconds(2))
        #expect(!presentation.isArmed && presentation.phase == .idle && handoffs == 0)
    }

    @Test func aNoncooperativeOldDelayCannotAdvanceTheNextSetup() async throws {
        var pending: [CheckedContinuation<Void, Never>] = []
        let presentation = OnboardingPresentation(sleep: { _ in
            await withCheckedContinuation { pending.append($0) }
        })
        var handoffs = 0
        presentation.onHandoff = { handoffs += 1 }
        presentation.begin()
        presentation.playbackReadinessChanged(true)
        try await liveLyricEventually { pending.count == 1 }
        presentation.begin()
        presentation.confirmLibraryConnection()
        try await liveLyricEventually { pending.count == 2 }
        pending.removeFirst().resume()
        for _ in 0..<20 { await Task.yield() }
        #expect(presentation.phase == .libraryConnected && handoffs == 0)
        presentation.cancel()
        pending.removeFirst().resume()
        for _ in 0..<20 { await Task.yield() }
        #expect(presentation.phase == .idle && !presentation.isArmed && handoffs == 0)
    }
}
