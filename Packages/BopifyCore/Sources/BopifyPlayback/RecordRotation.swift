import Foundation

public struct RecordRotation: Sendable {
    public enum StopStyle: Sendable { case brake, snap }
    private enum Mode: Sendable { case stopped, driving, braking }
    private static let cruiseSpeed = Double.pi / 6
    private static let driveRate = 6.0
    private static let deceleration = cruiseSpeed / 0.6
    private var anchorAngle = 0.0
    private var anchorSpeed = 0.0
    private var anchorTime: TimeInterval = 0
    private var mode: Mode = .stopped
    public init() {}

    public var stopTime: TimeInterval? {
        mode == .braking ? anchorTime + anchorSpeed / Self.deceleration : nil
    }

    public func angle(at time: TimeInterval) -> Double {
        let elapsed = max(0, time - anchorTime)
        switch mode {
        case .stopped: return anchorAngle
        case .driving:
            return anchorAngle + Self.cruiseSpeed * elapsed
                + (anchorSpeed - Self.cruiseSpeed) * (1 - exp(-Self.driveRate * elapsed)) / Self.driveRate
        case .braking:
            let duration = min(elapsed, anchorSpeed / Self.deceleration)
            return anchorAngle + anchorSpeed * duration - Self.deceleration * duration * duration / 2
        }
    }

    public func speed(at time: TimeInterval) -> Double {
        let elapsed = max(0, time - anchorTime)
        switch mode {
        case .stopped: return 0
        case .driving:
            return anchorSpeed + (Self.cruiseSpeed - anchorSpeed) * (1 - exp(-Self.driveRate * elapsed))
        case .braking:
            guard time < stopTime! else { return 0 }
            return max(0, anchorSpeed - Self.deceleration * elapsed)
        }
    }

    public func isMoving(at time: TimeInterval) -> Bool {
        mode == .driving || (stopTime.map { time < $0 } ?? false)
    }

    public mutating func setRunning(_ running: Bool, at time: TimeInterval, stopStyle: StopStyle = .brake) {
        if running {
            guard mode != .driving else { return }
        } else if stopStyle == .brake {
            guard mode == .driving else { return }
        }
        anchorAngle = angle(at: time)
        anchorSpeed = running || stopStyle == .brake ? speed(at: time) : 0
        anchorTime = time
        mode = running ? .driving : anchorSpeed > 0 ? .braking : .stopped
    }

    public mutating func setAngle(_ radians: Double, at time: TimeInterval) {
        anchorAngle = radians
        anchorSpeed = 0
        anchorTime = time
        mode = .stopped
    }
}
