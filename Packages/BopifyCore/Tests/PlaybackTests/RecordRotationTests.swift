import Testing
import BopifyPlayback

@Suite("RecordRotation") struct RecordRotationTests {
    @Test func driveAcceleratesWithoutRestartingOnRepeatedRequests() {
        var rotation = RecordRotation()
        rotation.setRunning(true, at: 0)
        let angle = rotation.angle(at: 0.5)
        let speed = rotation.speed(at: 0.5)
        #expect(angle > rotation.angle(at: 0.25))
        #expect(speed > rotation.speed(at: 0.25))
        #expect(rotation.isMoving(at: 0))
        rotation.setRunning(true, at: 0.25)
        #expect(rotation.angle(at: 0.5) == angle)
        #expect(rotation.speed(at: 0.5) == speed)
    }

    @Test func brakeEndsExactlyAtItsDeadline() throws {
        var rotation = RecordRotation()
        rotation.setRunning(true, at: 0)
        rotation.setRunning(false, at: 3)
        let stop = try #require(rotation.stopTime)
        #expect(rotation.isMoving(at: stop - 1e-9))
        #expect(!rotation.isMoving(at: stop))
        #expect(rotation.speed(at: stop) == 0)
        #expect(rotation.angle(at: stop + 100) == rotation.angle(at: stop))
        #expect(!rotation.isMoving(at: stop + 100))
        rotation.setRunning(false, at: 3.3)
        #expect(rotation.stopTime == stop)
    }

    @Test func pauseDuringSpinUpBrakesFromCurrentSpeed() {
        var rotation = RecordRotation()
        rotation.setRunning(true, at: 0)
        let angle = rotation.angle(at: 0.2)
        let speed = rotation.speed(at: 0.2)
        rotation.setRunning(false, at: 0.2)
        #expect(rotation.angle(at: 0.2) == angle)
        #expect(rotation.speed(at: 0.2) == speed)
        #expect(rotation.stopTime != nil)
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
        #expect(rotation.angle(at: 1.5) > 5)
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
