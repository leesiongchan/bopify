import Foundation

public struct RecordScrub: Sendable {
    public var positionMs: Int64 { Int64(clamping: UInt64(position.rounded())) }
    public private(set) var angleDelta = 0.0
    private var position: Double
    private let duration: Double
    private var previousAngle: Double?
    private var geometry: UInt64?

    public init(positionMs: Int64, durationMs: Int64) {
        duration = Double(max(0, durationMs))
        position = min(duration, Double(max(0, positionMs)))
    }

    public mutating func update(x: Double, y: Double, geometryID: UInt64) {
        guard x.isFinite, y.isFinite, hypot(x, y) >= 12 else {
            previousAngle = nil
            return
        }
        let angle = atan2(y, x)
        defer { previousAngle = angle; geometry = geometryID }
        guard geometry == geometryID, let previousAngle else { return }
        let delta = atan2(sin(angle - previousAngle), cos(angle - previousAngle))
        position = min(duration, max(0, position + delta * 60_000 / (2 * .pi)))
        angleDelta += delta
    }
}
