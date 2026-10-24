import Foundation
import Testing

@Suite("Now Playing commands")
struct NowPlayingControllerTests {
    @Test(arguments: [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude,
                      -.greatestFiniteMagnitude, Double(Int64.max) / 1000])
    func unrepresentableSeekPositionsAreIgnored(seconds: Double) {
        #expect(NowPlayingController.seekPositionMs(seconds: seconds) == nil)
    }

    @Test(arguments: [(12.3456, Int64(12_345)), (0.0, Int64(0)), (-0.5, Int64(-500))])
    func seekPositionsKeepMillisecondPrecision(seconds: Double, expected: Int64) {
        #expect(NowPlayingController.seekPositionMs(seconds: seconds) == expected)
    }
}
