import Foundation

public struct RecordRotation: Sendable {
    private var phase = 0.0
    private var startedAt: TimeInterval?
    public init() {}

    public func angle(at time: TimeInterval) -> Double {
        phase + (startedAt.map { max(0, time - $0) * .pi / 6 } ?? 0)
    }

    public mutating func setRunning(_ running: Bool, at time: TimeInterval) {
        guard running != (startedAt != nil) else { return }
        phase = angle(at: time)
        startedAt = running ? time : nil
    }

    public mutating func setAngle(_ radians: Double, at time: TimeInterval) {
        phase = radians
        if startedAt != nil { startedAt = time }
    }
}
