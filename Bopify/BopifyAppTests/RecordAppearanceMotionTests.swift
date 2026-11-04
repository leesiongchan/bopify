import Testing
import Foundation

@Suite("Physical appearance exchanges")
struct RecordAppearanceMotionTests {
    private let start = SuspendingClock.now
    private func time(_ seconds: Double) -> SuspendingClock.Instant { start.advanced(by: .seconds(seconds)) }
    private func playing() -> RecordAppearanceMotion {
        var motion = RecordAppearanceMotion(material: .classic, pattern: .original, at: start)
        motion.setVisible(true, at: start)
        return motion
    }
    private func settled(_ motion: RecordAppearanceMotion, _ choice: RecordAppearanceChoice) {
        let deck = motion.snapshot.deck(in: choice.family)
        #expect(deck.phase == .play)
        #expect(deck.mounted == choice)
        #expect(deck.labelChoice == choice)
        let frames = motion.snapshot.records.filter { $0.choice.family == choice.family }
        #expect(frames.filter { $0.to == .platter }.count == 1)
        #expect(Set(frames.map(\.choice)).count == frames.count)
    }

    @Test func needleClearsBeforeSwap() {
        var m = playing()
        m.select(.material(.glass), at: start)
        m.advance(to: time(0.13))
        #expect(m.snapshot.deck(in: .material).phase == .prepare)
        #expect(m.snapshot.records.first { $0.choice == .material(.classic) }?.to == .platter)
        m.advance(to: time(0.46))
        let d = m.snapshot.deck(in: .material)
        #expect(d.phase == .swap)
        #expect(d.needleLift == 1)
        #expect(d.armAngle == 90)
        #expect(d.speed == 0)
        m.advance(to: time(1.5))
        #expect(m.snapshot.deck(in: .material).phase == .restore)
        #expect(m.snapshot.deck(in: .material).needleLift == 1)
    }
    @Test func bothRecordsCrossTogether() {
        var m = playing()
        m.select(.pattern(.bloom), at: start)
        m.advance(to: time(0.89))
        let frames = m.snapshot.records.filter { $0.choice.family == .pattern && $0.from != $0.to }
        #expect(frames.count == 2)
        #expect(frames.allSatisfy { abs($0.progress - 0.5) < 0.001 })
        #expect(frames.contains { $0.from == .platter && $0.to == .edge })
        #expect(frames.contains { $0.from == .extracted && $0.to == .platter })
    }
    @Test func mountedLabelChangesAfterDocking() {
        var m = playing()
        m.select(.material(.nacre), at: start)
        m.advance(to: time(1))
        #expect(m.snapshot.deck(in: .material).labelChoice == .material(.classic))
        m.advance(to: time(1.33))
        #expect(m.snapshot.deck(in: .material).labelChoice == .material(.nacre))
    }
    @Test func loweringRestartsBothEqualMotors() {
        var m = playing()
        m.select(.material(.glass), at: start)
        m.select(.pattern(.bloom), at: start)
        m.advance(to: time(1.84))
        #expect(m.needsFrames)
        #expect(m.snapshot.deck(in: .material).speed == 45)
        #expect(m.snapshot.deck(in: .pattern).speed == 45)
        let before = m.snapshot.records.first { $0.choice == .material(.glass) }!.motorAngle
        m.advance(to: time(2.84))
        let after = m.snapshot.records.first { $0.choice == .material(.glass) }!.motorAngle
        #expect(abs(after - before - 45) < 0.001)
    }
    @Test func sameChoiceHasNoFlight() {
        var m = playing()
        m.select(.material(.classic), at: start)
        settled(m, .material(.classic))
    }
    @Test func replacementDuringPreparationKeepsArmParked() {
        var m = playing()
        m.select(.pattern(.bloom), at: start)
        m.select(.pattern(.carnival), at: time(0.2))
        m.advance(to: time(0.4401))
        #expect(abs(m.snapshot.deck(in: .pattern).armAngle + 90) < 0.01)
        #expect(m.snapshot.deck(in: .pattern).needleLift == 1)
        #expect(m.snapshot.deck(in: .pattern).speed == 0)
    }
    @Test func lastSelectionWinsDuringPrepare() {
        var m = playing()
        m.select(.pattern(.bloom), at: start)
        m.select(.pattern(.carnival), at: time(0.2))
        m.advance(to: time(6))
        settled(m, .pattern(.carnival))
    }
    @Test func lastSelectionWinsDuringSwap() {
        var m = playing()
        m.select(.material(.glass), at: start)
        m.select(.material(.nacre), at: time(0.8))
        m.advance(to: time(6))
        settled(m, .material(.nacre))
    }
    @Test func returningToMountedDuringPrepareIsSafe() {
        var m = playing()
        m.select(.material(.glass), at: start)
        m.select(.material(.classic), at: time(0.2))
        #expect(m.snapshot.deck(in: .material).needleLift == 1)
        m.advance(to: time(0.3))
        #expect(m.snapshot.deck(in: .material).needleLift == 1)
        m.advance(to: time(6))
        settled(m, .material(.classic))
    }
    @Test func selectingOutgoingDuringSwapLeavesExactlyOneMounted() {
        var m = playing()
        m.select(.pattern(.bloom), at: start)
        m.select(.pattern(.original), at: time(0.9))
        m.advance(to: time(6))
        settled(m, .pattern(.original))
    }
    @Test func familiesExchangeIndependently() {
        var m = playing()
        m.select(.material(.glass), at: start)
        m.advance(to: time(1))
        #expect(m.snapshot.deck(in: .pattern).phase == .play)
        #expect(m.snapshot.deck(in: .pattern).speed == 45)
        #expect(abs(m.snapshot.records.first { $0.choice == .pattern(.original) }!.motorAngle - 45) < 0.001)
    }
    @Test func pauseStopsCruiseButAllowsExchange() {
        var m = playing()
        m.setPaused(true, at: start)
        #expect(!m.needsFrames)
        m.select(.material(.glass), at: start)
        #expect(m.needsFrames)
        m.advance(to: time(3))
        settled(m, .material(.glass))
        #expect(!m.needsFrames)
        #expect(m.snapshot.deck(in: .material).speed == 0)
        m.setPaused(false, at: time(3))
        #expect(m.needsFrames)
    }
    @Test(arguments: [0.1, 0.7, 1.34, 1.5, 1.75])
    func reducedMotionDuringEveryPhaseSettlesLatest(_ seconds: Double) {
        var m = playing()
        m.select(.material(.glass), at: start)
        m.select(.material(.nacre), at: time(seconds))
        m.setReducedMotion(true, at: time(seconds))
        settled(m, .material(.nacre))
        #expect(!m.needsFrames)
    }
    @Test func hiddenDuringFlightSettlesWithoutFrames() {
        var m = playing()
        m.select(.pattern(.bloom), at: start)
        m.setVisible(false, at: time(0.8))
        settled(m, .pattern(.bloom))
        #expect(!m.needsFrames)
    }
    @Test func resizeSettlementCancelsOldFlight() {
        var m = playing()
        m.select(.material(.glass), at: start)
        m.settle(material: .nacre, pattern: .strata, at: time(0.8))
        m.advance(to: time(5))
        settled(m, .material(.nacre))
        settled(m, .pattern(.strata))
    }
    @Test func reopenUsesLatestSavedChoices() {
        var m = playing()
        m.setPaused(true, at: start)
        m.setVisible(false, at: start)
        m.select(.pattern(.carnival), at: time(1))
        m.setVisible(true, at: time(2))
        settled(m, .pattern(.carnival))
        #expect(!m.needsFrames)
    }
    @Test func longFrameGapDoesNotLoseSelection() {
        var m = playing()
        m.select(.pattern(.bloom), at: start)
        m.select(.pattern(.carnival), at: time(0.8))
        m.advance(to: time(100))
        settled(m, .pattern(.carnival))
    }
}
