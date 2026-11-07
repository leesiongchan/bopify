import Testing

@MainActor @Suite("Onboarding presentation", .serialized)
struct OnboardingPresentationTests {
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

    @Test func reducedMotionKeepsAcknowledgementBriefAndStillCompletes() async throws {
        let clock = LiveLyricTestClock()
        let presentation = OnboardingPresentation(sleep: { try await clock.sleep(for: $0) })
        defer { presentation.cancel() }
        presentation.begin()
        presentation.playbackReadinessChanged(true, reduceMotion: true)
        try #require(presentation.phase == .completing)
        try await liveLyricEventually { clock.pendingDelays.count == 1 }
        #expect(clock.pendingDelays.allSatisfy { $0 <= .milliseconds(200) })
        clock.advance(by: .seconds(1))
        try await liveLyricEventually { presentation.phase == .handoff && clock.pendingDelays.count == 1 }
        #expect(clock.pendingDelays.allSatisfy { $0 <= .milliseconds(200) })
        clock.advance(by: .seconds(1))
        try await liveLyricEventually { presentation.phase == .idle }
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
