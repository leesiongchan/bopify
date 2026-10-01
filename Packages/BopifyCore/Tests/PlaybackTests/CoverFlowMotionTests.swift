import Foundation
import Testing
@testable import BopifyPlayback

@Suite("Cover Flow motion")
struct CoverFlowMotionTests {
    @Test func slowReleaseSettlesOnNearestCover() {
        #expect(CoverFlowMotion.restingIndex(position: 3.4, velocity: 0, count: 10) == 3)
        #expect(CoverFlowMotion.restingIndex(position: 3.6, velocity: 0, count: 10) == 4)
    }

    @Test func flingCarriesSeveralCovers() {
        // 10 covers/s at the standard 0.998 deceleration projects about 5 covers ahead.
        #expect(CoverFlowMotion.restingIndex(position: 3, velocity: 10, count: 50) == 8)
        #expect(CoverFlowMotion.restingIndex(position: 20, velocity: -10, count: 50) == 15)
    }

    @Test func restingIndexClampsToTheList() {
        #expect(CoverFlowMotion.restingIndex(position: 8, velocity: 100, count: 10) == 9)
        #expect(CoverFlowMotion.restingIndex(position: 1, velocity: -100, count: 10) == 0)
        #expect(CoverFlowMotion.restingIndex(position: -0.8, velocity: 0, count: 10) == 0)
    }

    @Test func rubberBandResistsPastTheEnds() {
        #expect(CoverFlowMotion.rubberBanded(4, count: 10) == 4)
        #expect(CoverFlowMotion.rubberBanded(-1, count: 10) == -0.3)
        #expect(abs(CoverFlowMotion.rubberBanded(11, count: 10) - 9.6) < 1e-9)
    }

    @Test func centeredCoverFacesForward() {
        let center = CoverFlowMotion.transform(distance: 0, reduceMotion: false)
        #expect(center.rotation == 0)
        #expect(center.scale == 1)
        #expect(center.offset == 0)
        #expect(center.opacity == 1)
    }

    @Test func transformIsContinuousThroughTheCenter() {
        var previous = CoverFlowMotion.transform(distance: -2, reduceMotion: false)
        for step in 1...400 {
            let next = CoverFlowMotion.transform(distance: -2 + Double(step) * 0.01, reduceMotion: false)
            #expect(abs(next.rotation - previous.rotation) < 1)
            #expect(abs(next.scale - previous.scale) < 0.01)
            #expect(abs(next.offset - previous.offset) < 1)
            #expect(abs(next.opacity - previous.opacity) < 0.01)
            previous = next
        }
    }

    @Test func sideCoversTiltAwayAndReduceMotionFlattensThem() {
        #expect(CoverFlowMotion.transform(distance: 1, reduceMotion: false).rotation == -48)
        #expect(CoverFlowMotion.transform(distance: -1, reduceMotion: false).rotation == 48)
        #expect(CoverFlowMotion.transform(distance: 1, reduceMotion: true).rotation == 0)
        #expect(CoverFlowMotion.transform(distance: 1, reduceMotion: false).scale == 0.8)
    }

    @Test func coversFadeOutAtTheStripsReach() {
        let opacity = { CoverFlowMotion.transform(distance: $0, reduceMotion: false, reach: 4).opacity }
        #expect(opacity(1) == 1)
        #expect(opacity(3) > 0)
        #expect(opacity(4) == 0)
        #expect(CoverFlowMotion.transform(distance: 3, reduceMotion: false).opacity == 0)
    }

    @Test func wheelNotchMovesExactlyOneCover() {
        #expect(CoverFlowMotion.wheelTarget(from: 4, delta: -3, count: 10) == 5)
        #expect(CoverFlowMotion.wheelTarget(from: 4, delta: 0.5, count: 10) == 3)
        #expect(CoverFlowMotion.wheelTarget(from: 9, delta: -1, count: 10) == 9)
        #expect(CoverFlowMotion.wheelTarget(from: 0, delta: 1, count: 10) == 0)
        #expect(CoverFlowMotion.wheelTarget(from: 4, delta: 0, count: 10) == 4)
    }

    @Test func glideMovesTheTargetByPointsAndStaysInTheList() {
        // Negative deltas advance, like the wheel; one spacing of travel is one cover.
        #expect(CoverFlowMotion.glideTarget(from: 4, delta: -CoverFlowMotion.spacing, count: 10) == 5)
        #expect(CoverFlowMotion.glideTarget(from: 4, delta: CoverFlowMotion.spacing / 2, count: 10) == 3.5)
        #expect(CoverFlowMotion.glideTarget(from: 8.5, delta: -1000, count: 10) == 9)
        #expect(CoverFlowMotion.glideTarget(from: 0.5, delta: 1000, count: 10) == 0)
    }

    @Test func velocityUsesOnlyRecentSamples() {
        var tracker = CoverFlowVelocity()
        tracker.add(position: 0, at: 0)
        tracker.add(position: 1, at: 0.05)
        tracker.add(position: 2, at: 0.1)
        #expect(abs(tracker.velocity - 20) < 1e-9)
        // A pause before release leaves no fling.
        tracker.add(position: 2, at: 0.5)
        #expect(tracker.velocity == 0)
    }

    @Test func springSettlesExactlyOnTarget() {
        var spring = CoverFlowSpring(position: 0, velocity: 0, target: 5)
        var frames = 0
        while !spring.isSettled && frames < 600 {
            spring.step(dt: 1.0 / 120, reduceMotion: false)
            frames += 1
        }
        #expect(spring.isSettled)
        #expect(spring.position == 5)
        #expect(frames < 240)
    }

    @Test func springCarriesReleaseVelocityAndStaysNearTarget() {
        var spring = CoverFlowSpring(position: 3, velocity: 8, target: 4)
        spring.step(dt: 1.0 / 120, reduceMotion: false)
        #expect(spring.position > 3)
        var maximum = spring.position
        for _ in 0..<240 { spring.step(dt: 1.0 / 120, reduceMotion: false); maximum = max(maximum, spring.position) }
        // A slight bounce is fine; flying far past the target is not.
        #expect(maximum < 4.5)
        #expect(spring.position == 4)
    }

    @Test func reducedMotionSpringNeverOvershoots() {
        var spring = CoverFlowSpring(position: 0, velocity: 0, target: 3)
        for _ in 0..<240 {
            spring.step(dt: 1.0 / 120, reduceMotion: true)
            #expect(spring.position <= 3)
        }
        #expect(spring.position == 3)
    }
}
