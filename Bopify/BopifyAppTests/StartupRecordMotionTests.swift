import Foundation
import Testing

@Suite("Startup record motion")
struct StartupRecordMotionTests {
    @Test func workAcceleratesWithoutAnAngleJump() {
        var motion = StartupRecordMotion()
        motion.update(.working, at: 10)
        #expect(motion.sample(at: 10).angle == 0)
        #expect(motion.sample(at: 10).velocity == 0)
        let early = motion.sample(at: 10.1)
        let cruising = motion.sample(at: 13)
        #expect(early.velocity > 0 && early.velocity < cruising.velocity)
        #expect(early.angle > 0 && early.angle < 20)
        #expect(abs(cruising.velocity - 200) < 0.1)
    }

    @Test func interruptingSpinAndSettlePreservesTheVisibleAngle() {
        var motion = StartupRecordMotion()
        motion.update(.working, at: 1)
        let spinning = motion.sample(at: 1.37)
        motion.update(.idle, at: 1.37)
        #expect(abs(motion.sample(at: 1.37).angle - spinning.angle) < 1e-8)
        let settling = motion.sample(at: 1.55)
        motion.update(.working, at: 1.55)
        #expect(abs(motion.sample(at: 1.55).angle - settling.angle) < 1e-8)
    }

    @Test func completionSettlesUprightWithoutAnExtraTurn() {
        var motion = StartupRecordMotion(angle: 90)
        motion.update(.working, at: 0)
        let before = motion.sample(at: 0.25)
        motion.update(.idle, at: 0.25, settleDuration: 0.2)
        let settled = motion.sample(at: 0.46)
        #expect(abs(settled.angle.truncatingRemainder(dividingBy: 360)) < 1e-8)
        #expect(settled.velocity == 0)
        #expect(abs(settled.angle - before.angle) <= 180)
        #expect(abs(motion.sample(at: 5).angle - settled.angle) < 1e-8)
    }

    @Test func hiddenTimeDoesNotAdvanceTheRecord() {
        var motion = StartupRecordMotion()
        motion.update(.working, at: 0)
        let before = motion.sample(at: 0.4)
        motion.update(.paused, at: 0.4)
        #expect(abs(motion.sample(at: 100).angle - before.angle) < 1e-8)
        #expect(motion.sample(at: 100).velocity == 0)
        motion.update(.working, at: 100)
        #expect(abs(motion.sample(at: 100).angle - before.angle) < 1e-8)
    }

    @Test func completionDoesNotShortenAnExistingUprightSettle() {
        var motion = StartupRecordMotion(angle: 90)
        motion.update(.idle, at: 0, settleDuration: 1)
        let original = motion.sample(at: 0.2)
        motion.update(.idle, at: 0.2, settleDuration: 0.2)
        #expect(abs(motion.sample(at: 0.2).angle - original.angle) < 1e-8)
        #expect(motion.sample(at: 0.41).velocity != 0)
        #expect(motion.sample(at: 1).velocity == 0)
    }

    @Test func completionWaitsForLiftFlipTiltAndUprightTogether() {
        var motion = StartupRecordMotion(angle: 90)
        motion.update(.idle, at: 0, settleDuration: 1)
        var animations = StartupRecordAnimationState()
        let lift = animations.begin(.lift), flip = animations.begin(.flip), tilt = animations.begin(.tilt)
        #expect(!animations.isSettled(motion: motion, at: 1))
        animations.finish(.lift, token: lift)
        animations.finish(.flip, token: flip)
        #expect(!animations.isSettled(motion: motion, at: 1))
        animations.finish(.tilt, token: tilt)
        #expect(!animations.isSettled(motion: motion, at: 0.5))
        #expect(!animations.isSettled(motion: motion, at: 0.999999))
        #expect(animations.isSettled(motion: motion, at: 1))
    }

    @Test func interruptedAnimationCompletionCannotReleaseItsReplacement() {
        var animations = StartupRecordAnimationState()
        let old = animations.begin(.flip), current = animations.begin(.flip)
        animations.finish(.flip, token: old)
        #expect(animations.isCurrent(.flip, token: current))
        #expect(!animations.isSettled(motion: StartupRecordMotion(), at: 0))
        animations.finish(.flip, token: current)
        #expect(animations.isSettled(motion: StartupRecordMotion(), at: 0))
    }

    @Test func hiddenPresentationResetInvalidatesAnimationCallbacks() {
        var animations = StartupRecordAnimationState()
        let old = animations.begin(.lift)
        animations.cancelAll()
        let current = animations.begin(.lift)
        animations.finish(.lift, token: old)
        #expect(animations.isCurrent(.lift, token: current))
        animations.cancelAll()
        var motion = StartupRecordMotion(angle: 52)
        motion.update(.idle, at: 1)
        #expect(!animations.isSettled(motion: motion, at: 1))
        #expect(animations.isSettled(motion: motion, at: 2))
    }

    @Test func startingSpinAtAnUprightAngleIsNotACompletedPose() {
        var motion = StartupRecordMotion()
        motion.update(.working, at: 0)
        #expect(!motion.isSettled(at: 0))
    }
}
