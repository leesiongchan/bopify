import Foundation
import Testing
import BopifyPlayback

@Suite("RecordRotation") struct RecordRotationTests {
    @Test func rotationPreservesPhase() {
        var rotation = RecordRotation()
        rotation.setRunning(true, at: 0)
        #expect(abs(rotation.angle(at: 3) - .pi / 2) < 0.00001)
        rotation.setRunning(false, at: 3)
        #expect(abs(rotation.angle(at: 13) - .pi / 2) < 0.00001)
        rotation.setRunning(true, at: 13)
        #expect(abs(rotation.angle(at: 16) - .pi) < 0.00001)
        rotation.setRunning(true, at: 16)
        #expect(abs(rotation.angle(at: 19) - 1.5 * .pi) < 0.00001)
    }
    @Test func gestureRebasesAmbientWithoutSnapping() {
        var rotation = RecordRotation()
        rotation.setRunning(true, at: 0)
        rotation.setRunning(false, at: 3)
        rotation.setAngle(5, at: 4)
        #expect(rotation.angle(at: 5) == 5)
        rotation.setRunning(true, at: 5)
        #expect(abs(rotation.angle(at: 6) - 5 - .pi / 6) < 0.00001)
    }
}
