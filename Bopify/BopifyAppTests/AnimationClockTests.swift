import SwiftUI
import Testing

@MainActor @Suite("Animation clocks")
struct AnimationClockTests {
    @Test func visualProgressUsesASuspendingInstant() throws {
        let start = SuspendingClock.now
        var timing = RecordLoadTiming(startedAt: start)
        #expect(timing.progress(at: start.advanced(by: .milliseconds(200))) > 0)
        #expect(timing.progress(at: start.advanced(by: .seconds(10))) == 0.36)
        timing.confirm(at: start.advanced(by: .milliseconds(11_500)))
        let finish = try #require(timing.finishedAt)
        #expect(abs((start.duration(to: finish) / .seconds(1)) - 12.652) < 0.000001)
        #expect(timing.progress(at: start.advanced(by: .seconds(12))) < 1)
        #expect(timing.progress(at: finish) == 1)
    }

    @Test func anInterruptedArtworkBlendKeepsTheCurrentColorsOnTheSameClock() throws {
        let start = SuspendingClock.now
        var morph = ArtworkMorphState(image: Image(systemName: "circle"), occurrenceID: "A")
        morph.duration = 0.65
        morph.transition(to: Image(systemName: "square"), occurrenceID: "B", at: start)
        let halfway = start.advanced(by: .milliseconds(325))
        #expect(abs(morph.progress(at: halfway) - 0.5) < 0.000001)
        #expect(abs((try #require(morph.frames(at: halfway).last)).opacity - 0.5) < 0.000001)
        morph.transition(to: Image(systemName: "triangle"), occurrenceID: "C", at: halfway)
        #expect(morph.frames(at: halfway).count == 2)
        #expect(morph.frames(at: halfway).last?.opacity == 0)
        morph.finish()
        #expect(morph.frames(at: halfway).count == 1)
        #expect(morph.frames(at: halfway).last?.opacity == 1)
    }
}
