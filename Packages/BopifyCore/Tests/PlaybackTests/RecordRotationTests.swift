import Foundation
import Testing
import BopifyPlayback

@Suite("RecordRotation") struct RecordRotationTests {
    @Test func driveIntegratesSpinUpInsteadOfStartingAtCruise() {
        var rotation = RecordRotation()
        rotation.setRunning(true, at: 0)
        #expect(abs(rotation.angle(at: 0.5) - 0.17887766653910667) < 1e-10)
        #expect(abs(rotation.speed(at: 0.5) - 0.49753032756025645) < 1e-10)
        #expect(rotation.isMoving(at: 0))
        rotation.setRunning(true, at: 0.25)
        #expect(abs(rotation.angle(at: 0.5) - 0.17887766653910667) < 1e-10)
        #expect(abs(rotation.speed(at: 0.5) - 0.49753032756025645) < 1e-10)
    }

    @Test func brakeEndsExactlyAtItsDeadline() throws {
        var rotation = RecordRotation()
        rotation.setRunning(true, at: 0)
        rotation.setRunning(false, at: 3)
        let stop = try #require(rotation.stopTime)
        #expect(abs(stop - 3.5999999908620124) < 1e-10)
        #expect(rotation.isMoving(at: stop - 1e-9))
        #expect(!rotation.isMoving(at: stop))
        #expect(rotation.speed(at: stop) == 0)
        #expect(abs(rotation.angle(at: stop) - 1.6406094934190971) < 1e-10)
        #expect(rotation.angle(at: stop + 100) == rotation.angle(at: stop))
        #expect(!rotation.isMoving(at: stop + 100))
        rotation.setRunning(false, at: 3.3)
        #expect(rotation.stopTime == stop)
    }

    @Test func pauseDuringSpinUpBrakesFromCurrentSpeed() throws {
        var rotation = RecordRotation()
        rotation.setRunning(true, at: 0)
        let angle = rotation.angle(at: 0.2)
        let speed = rotation.speed(at: 0.2)
        rotation.setRunning(false, at: 0.2)
        #expect(rotation.angle(at: 0.2) == angle)
        #expect(rotation.speed(at: 0.2) == speed)
        let stop = try #require(rotation.stopTime)
        #expect(abs(stop - (0.2 + 0.6 * (1 - exp(-1.2)))) < 1e-10)
        #expect(stop < 0.8)
    }

    @Test func resumeDuringBrakePreservesAngleAndSpeed() throws {
        var rotation = RecordRotation()
        rotation.setRunning(true, at: 0)
        rotation.setRunning(false, at: 0.2)
        let stop = try #require(rotation.stopTime)
        let resume = (0.2 + stop) / 2
        let angle = rotation.angle(at: resume)
        let speed = rotation.speed(at: resume)
        rotation.setRunning(true, at: resume)
        #expect(rotation.angle(at: resume) == angle)
        #expect(rotation.speed(at: resume) == speed)
        #expect(rotation.stopTime == nil)
        #expect(rotation.speed(at: resume + 0.1) > speed)
        #expect(rotation.isMoving(at: stop + 1))
    }

    @Test(arguments: [false, true]) func snapOverridesDriveAndBrake(braking: Bool) {
        var rotation = RecordRotation()
        rotation.setRunning(true, at: 0)
        if braking { rotation.setRunning(false, at: 0.2) }
        let angle = rotation.angle(at: 0.3)
        rotation.setRunning(false, at: 0.3, stopStyle: .snap)
        #expect(rotation.angle(at: 100) == angle)
        #expect(rotation.speed(at: 0.3) == 0)
        #expect(!rotation.isMoving(at: 0.3))
        #expect(rotation.stopTime == nil)
    }

    @Test(arguments: [false, true]) func gestureRebasesAtRest(braking: Bool) {
        var rotation = RecordRotation()
        rotation.setRunning(true, at: 0)
        if braking { rotation.setRunning(false, at: 0.2) }
        rotation.setAngle(5, at: 0.3)
        #expect(rotation.angle(at: 1) == 5)
        #expect(rotation.speed(at: 1) == 0)
        #expect(!rotation.isMoving(at: 1))
        #expect(rotation.stopTime == nil)
        rotation.setRunning(true, at: 1)
        #expect(rotation.speed(at: 1) == 0)
        #expect(abs(rotation.angle(at: 1.5) - 5.178877666539107) < 1e-10)
    }

    @Test func earlierQueriesClampToTheAnchor() {
        var rotation = RecordRotation()
        rotation.setAngle(5, at: 10)
        rotation.setRunning(true, at: 10)
        #expect(rotation.angle(at: 9) == 5)
        #expect(rotation.speed(at: 9) == 0)
        rotation.setRunning(false, at: 11)
        #expect(rotation.angle(at: 9) == rotation.angle(at: 11))
        #expect(rotation.speed(at: 9) == rotation.speed(at: 11))
    }
}
