import Foundation
import Testing
import BopifyPlayback

@Suite("RecordScrub") struct RecordScrubTests {
    @Test func relativeScrubWrapsAndReverses() {
        var scrub = RecordScrub(positionMs: 30_000, durationMs: 180_000)
        scrub.update(x: 0, y: -90, geometryID: 0)
        scrub.update(x: 90, y: 0, geometryID: 0)
        #expect(scrub.positionMs == 45_000)
        #expect(abs(scrub.angleDelta - .pi / 2) < 0.00001)
        scrub.update(x: 0, y: -90, geometryID: 0)
        #expect(scrub.positionMs == 30_000)
        for _ in 0..<2 {
            for point in [(90.0, 0.0), (0, 90), (-90, 0), (0, -90)] {
                scrub.update(x: point.0, y: point.1, geometryID: 0)
            }
        }
        #expect(scrub.positionMs == 150_000)
    }
    @Test func crossesAngleSeamInBothDirections() {
        var scrub = RecordScrub(positionMs: 30_000, durationMs: 180_000)
        scrub.update(x: -90, y: 1, geometryID: 0)
        scrub.update(x: -90, y: -1, geometryID: 0)
        #expect(scrub.positionMs > 30_000 && scrub.positionMs < 31_000)
        scrub.update(x: -90, y: 1, geometryID: 0)
        #expect(scrub.positionMs == 30_000)
    }
    @Test func deadZoneInvalidInputAndGeometryRebase() {
        var scrub = RecordScrub(positionMs: 30_000, durationMs: 180_000)
        scrub.update(x: 90, y: 0, geometryID: 0)
        scrub.update(x: 0, y: 0, geometryID: 0)
        scrub.update(x: -90, y: 0, geometryID: 0)
        #expect(scrub.positionMs == 30_000)
        scrub.update(x: .nan, y: 0, geometryID: 0)
        scrub.update(x: 0, y: 90, geometryID: 0)
        #expect(scrub.positionMs == 30_000)
        scrub.update(x: 90, y: 0, geometryID: 1)
        #expect(scrub.positionMs == 30_000)
        scrub.update(x: 0, y: 90, geometryID: 1)
        #expect(scrub.positionMs == 45_000)
    }
    @Test func boundsDiscardOvershootForImmediateReversal() {
        var scrub = RecordScrub(positionMs: 5_000, durationMs: 10_000)
        scrub.update(x: 0, y: -90, geometryID: 0)
        scrub.update(x: 90, y: 0, geometryID: 0)
        #expect(scrub.positionMs == 10_000)
        scrub.update(x: 90, y: -10, geometryID: 0)
        #expect(scrub.positionMs < 10_000)
        scrub.update(x: 0, y: -90, geometryID: 0)
        #expect(scrub.positionMs == 0)
        scrub.update(x: 10, y: -90, geometryID: 0)
        #expect(scrub.positionMs > 0)
    }
}
