import SwiftUI
import Testing

@MainActor @Suite("Animation clocks")
struct AnimationClockTests {
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
