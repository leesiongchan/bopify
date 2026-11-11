import Foundation
import Testing

@MainActor @Suite("Startup window layout", .serialized)
struct StartupWindowLayoutTests {
    @Test func measurementsAreSeparatedByWidthAndDiscardedWhenTheFormIsRemounted() {
        let layout = StartupWindowLayout()
        let narrow = StartupWindowLayout.MeasurementKey(identity: "library", width: 390)
        let wide = StartupWindowLayout.MeasurementKey(identity: "library", width: 430)
        layout.activateContent("library")
        layout.remember(contentHeight: 400, for: narrow, prepared: true)
        #expect(layout.measuredHeight(for: wide) == nil)
        layout.remember(contentHeight: 365, for: wide)
        #expect(layout.measuredHeight(for: narrow) == 400 && layout.measuredHeight(for: wide) == 365)
        layout.activateContent("playback")
        layout.activateContent("library")
        #expect(layout.measuredHeight(for: narrow) == nil && !layout.hasPreparedMeasurement(for: "library"))
        layout.remember(contentHeight: 600, for: .init(identity: "playback", width: 430))
        #expect(layout.measuredHeight(for: wide) == nil, "A late outgoing form cannot repopulate the current form's cache")
    }

    @Test func aLargerLibraryFormDoesNotReserveBothTheOldRecordAndTheNewForm() {
        let layout = StartupWindowLayout()
        defer { layout.cancelPendingResize() }
        layout.useScreen(height: 900)
        layout.measure(contentHeight: 200)
        layout.useStep(.library(.idle))
        layout.measure(contentHeight: 400)
        let libraryHeight: CGFloat = 661
        #expect(layout.height == libraryHeight)
        #expect(layout.recordScale == 0.55)
    }

    @Test func libraryScaleRestoresTheSmallerRecordAndKeepsTheOutgoingWindowUntilItsFade() async throws {
        let clock = LiveLyricTestClock()
        let layout = StartupWindowLayout(sleep: { try await clock.sleep(for: $0) })
        defer { layout.cancelPendingResize() }
        layout.useScreen(height: 900)
        let previous = layout.height
        let compactHeight: CGFloat = 421
        layout.useStep(.library(.idle))
        #expect(layout.recordScale == 0.55)
        #expect(layout.height == previous)
        try await liveLyricEventually { clock.pendingDelays.count == 1 }
        clock.advance(by: .milliseconds(330))
        try await liveLyricEventually { layout.height == compactHeight }
        #expect(layout.height == compactHeight)
        layout.useStep(.signIn(.idle))
        #expect(layout.recordScale == 0.88 && layout.height == previous)
    }

    @Test func libraryRecordAdaptsToMeasuredPermissionContentOnAShortScreen() {
        let layout = StartupWindowLayout()
        defer { layout.cancelPendingResize() }
        layout.useScreen(height: 600)
        layout.useStep(.library(.idle))
        layout.measure(contentHeight: 420)
        #expect(layout.recordScale < 0.55)
        #expect(82 + 324 * layout.recordScale + 420 <= 600)
        #expect(layout.height == 600, "The actual growing total commits directly without an artificial overshoot")
    }

    @Test func returningToWelcomeCancelsThePreviousCompactScaleContraction() async throws {
        var pending: [CheckedContinuation<Void, Never>] = []
        let layout = StartupWindowLayout(sleep: { _ in
            await withCheckedContinuation { pending.append($0) }
        })
        layout.useScreen(height: 900)
        let previous = layout.height
        layout.useStep(.library(.idle))
        try await liveLyricEventually { pending.count == 1 }
        layout.useStep(.signIn(.idle))
        pending.removeFirst().resume()
        for _ in 0..<20 { await Task.yield() }
        #expect(layout.height == previous && layout.recordScale == 0.88)
        layout.cancelPendingResize()
    }

    @Test(arguments: [StartupStep.playback(.entry), .playback(.working), .playback(.failure), .completion])
    func directPlaybackAndCompletionUseTheCompactRecord(step: StartupStep) {
        let layout = StartupWindowLayout()
        defer { layout.cancelPendingResize() }
        layout.useScreen(height: 900)
        layout.useStep(step)
        #expect(step.isCompact)
        #expect(layout.recordScale == 0.55)
        layout.measure(contentHeight: 240)
        #expect(layout.recordScale == 0.55)
    }

    @Test func theCompactRecordCarriesFromLibraryThroughPlaybackAndCompletion() async throws {
        let clock = LiveLyricTestClock()
        let layout = StartupWindowLayout(sleep: { try await clock.sleep(for: $0) })
        defer { layout.cancelPendingResize() }
        layout.useScreen(height: 900)
        layout.useStep(.library(.idle))
        layout.measure(contentHeight: 200)
        try await liveLyricEventually { clock.pendingDelays.count == 1 }
        clock.advance(by: .milliseconds(330))
        let compactHeight: CGFloat = 461
        try await liveLyricEventually { layout.height == compactHeight }
        for step in [StartupStep.library(.connected), .playback(.entry), .playback(.working), .playback(.failure), .completion] {
            layout.useStep(step)
            #expect(layout.recordScale == 0.55 && layout.height == compactHeight)
        }
        #expect(clock.pendingDelays.isEmpty)
        layout.useStep(.signIn(.idle))
        #expect(!StartupStep.signIn(.idle).isCompact && layout.recordScale == 0.88)
    }

    @Test func directPlaybackKeepsMeasuredContentInsideAShortScreen() {
        let layout = StartupWindowLayout()
        defer { layout.cancelPendingResize() }
        layout.useScreen(height: 600)
        layout.useStep(.playback(.working))
        layout.measure(contentHeight: 420)
        #expect(layout.recordScale < 0.55)
        #expect(82 + 324 * layout.recordScale + 420 <= 600)
        #expect(layout.height == 600, "The incoming compact form fits in the first allocated target")
    }

    @Test func contentGrowsTheWindowWithoutScalingTheRecord() {
        let layout = StartupWindowLayout()
        layout.useScreen(height: 900)
        let scale = layout.recordScale
        layout.measure(contentHeight: 200)
        let first = layout.height
        layout.measure(contentHeight: 300)
        #expect(layout.height - first == 100)
        #expect(layout.height == ceil(82 + 324 * scale + 300))
        #expect(layout.recordScale == scale && scale == 0.88)
    }

    @Test func contractionWaitsForTheOutgoingContent() async throws {
        let clock = LiveLyricTestClock()
        let layout = StartupWindowLayout(sleep: { try await clock.sleep(for: $0) })
        defer { layout.cancelPendingResize() }
        layout.useScreen(height: 900)
        let previous = layout.height
        layout.measure(contentHeight: 80)
        #expect(layout.height == previous)
        try await liveLyricEventually { clock.pendingDelays.count == 1 }
        #expect(clock.pendingDelays == [.milliseconds(330)])
        clock.advance(by: .milliseconds(329))
        for _ in 0..<10 { await Task.yield() }
        #expect(layout.height == previous)
        clock.advance(by: .milliseconds(1))
        try await liveLyricEventually { layout.height < previous }
        #expect(layout.height == ceil(82 + 324 * layout.recordScale + 80))
    }

    @Test func restoringTheCommittedHeightCancelsAnOlderContraction() async throws {
        let clock = LiveLyricTestClock()
        let layout = StartupWindowLayout(sleep: { try await clock.sleep(for: $0) })
        defer { layout.cancelPendingResize() }
        layout.useScreen(height: 900)
        layout.measure(contentHeight: 250)
        let previous = layout.height
        layout.measure(contentHeight: 100)
        try await liveLyricEventually { clock.pendingDelays.count == 1 }
        layout.measure(contentHeight: 250)
        try await liveLyricEventually { clock.pendingDelays.isEmpty }
        clock.advance(by: .seconds(1))
        #expect(layout.height == previous)
    }

    @Test func supersededNoncooperativeContractionsCannotResizeTheNewStep() async throws {
        var pending: [CheckedContinuation<Void, Never>] = []
        let layout = StartupWindowLayout(sleep: { _ in
            await withCheckedContinuation { pending.append($0) }
        })
        layout.useScreen(height: 900)
        let previous = layout.height
        layout.measure(contentHeight: 80)
        try await liveLyricEventually { pending.count == 1 }
        layout.measure(contentHeight: 100)
        try await liveLyricEventually { pending.count == 2 }
        pending.removeFirst().resume()
        for _ in 0..<20 { await Task.yield() }
        #expect(layout.height == previous)
        pending.removeFirst().resume()
        try await liveLyricEventually { layout.height < previous }
        #expect(layout.height == ceil(82 + 324 * layout.recordScale + 100))
        layout.cancelPendingResize()
    }

    @Test func leavingSetupCancelsItsPendingSizeChange() async throws {
        let clock = LiveLyricTestClock()
        let layout = StartupWindowLayout(sleep: { try await clock.sleep(for: $0) })
        layout.useScreen(height: 900)
        let previous = layout.height
        layout.measure(contentHeight: 80)
        try await liveLyricEventually { clock.pendingDelays.count == 1 }
        layout.cancelPendingResize()
        try await liveLyricEventually { clock.pendingDelays.isEmpty }
        clock.advance(by: .seconds(1))
        #expect(layout.height == previous)
    }

    @Test func screenConstraintsChangeScaleButStepsDoNot() {
        let layout = StartupWindowLayout()
        layout.useScreen(height: 600)
        let scale = layout.recordScale
        #expect(scale < 0.88 && scale > 0.25)
        layout.measure(contentHeight: 600)
        #expect(layout.height == 600)
        #expect(layout.recordScale == scale)
        layout.useScreen(height: 900)
        #expect(layout.recordScale == 0.88)
        #expect(layout.height <= 900)
    }

    @Test func invalidAndSubpointMeasurementsDoNotMoveTheWindow() {
        let layout = StartupWindowLayout()
        for invalid in [CGFloat.nan, .infinity, -.infinity, -1, 0, 0.8] { layout.useScreen(height: invalid) }
        #expect(!layout.isManaged)
        layout.useScreen(height: 900)
        let previous = layout.height
        for invalid in [CGFloat.nan, .infinity, -.infinity, -1, 0, 160.3] {
            layout.measure(contentHeight: invalid)
        }
        #expect(layout.height == previous && layout.recordScale == 0.88)
    }

    @Test func fractionalGeometryProducesAnIntegralTargetInsideTheScreen() {
        let layout = StartupWindowLayout()
        layout.useScreen(height: 900.8)
        layout.measure(contentHeight: 200.2)
        #expect(layout.height == 568)
        layout.measure(contentHeight: 201.1)
        #expect(layout.height == 569)
        layout.measure(contentHeight: 1200)
        #expect(layout.height == 900)
        layout.useScreen(height: 600.8)
        #expect(layout.height == 600)
        #expect(layout.recordScale == CGFloat(600 - 82 - 360) / 324)
    }
}
