import Foundation
import BopifyPlayback

enum StartupAnimationTiming {
    static let maximumCompletionWait: Duration = .seconds(3)
}

/// Completion callbacks from an interrupted animation cannot release a newer pose.
struct StartupRecordAnimationState {
    enum Channel: Hashable { case lift, flip, tilt }
    private var pending: [Channel: UUID] = [:]

    mutating func begin(_ channel: Channel) -> UUID {
        let token = UUID()
        pending[channel] = token
        return token
    }

    func isCurrent(_ channel: Channel, token: UUID) -> Bool { pending[channel] == token }

    mutating func finish(_ channel: Channel, token: UUID) {
        if isCurrent(channel, token: token) { pending[channel] = nil }
    }

    mutating func cancelAll() { pending = [:] }

    func isSettled(motion: StartupRecordMotion, at time: TimeInterval) -> Bool {
        pending.isEmpty && motion.isSettled(at: time)
    }
}

/// Reuses the player's analytic drive, with a short interruptible upright settle for setup.
struct StartupRecordMotion {
    enum Activity: Equatable { case idle, working, paused }
    struct Sample {
        let angle: Double
        let velocity: Double
    }

    private struct Settle {
        let began: TimeInterval
        let duration: TimeInterval
        let origin: Sample
        let target: Double

        func sample(at time: TimeInterval) -> Sample {
            let elapsed = max(0, time - began)
            guard elapsed < duration else { return Sample(angle: target, velocity: 0) }
            let t = elapsed / duration, t2 = t * t, t3 = t2 * t
            let angle = (2 * t3 - 3 * t2 + 1) * origin.angle
                + (t3 - 2 * t2 + t) * duration * origin.velocity
                + (-2 * t3 + 3 * t2) * target
            let velocity = (6 * t2 - 6 * t) * origin.angle / duration
                + (3 * t2 - 4 * t + 1) * origin.velocity
                + (-6 * t2 + 6 * t) * target / duration
            return Sample(angle: angle, velocity: velocity)
        }
    }

    // RecordRotation cruises at 5 rpm; the setup illustration turns at 33⅓ rpm.
    private static let angleScale = 1200 / Double.pi
    private var rotation = RecordRotation()
    private var activity: Activity = .paused
    private var settle: Settle?

    init(angle: Double = 0) { rotation.setAngle(angle / Self.angleScale, at: 0) }

    func sample(at time: TimeInterval) -> Sample {
        if let settle { return settle.sample(at: time) }
        return Sample(angle: rotation.angle(at: time) * Self.angleScale,
                      velocity: rotation.speed(at: time) * Self.angleScale)
    }

    func isSettled(at time: TimeInterval) -> Bool {
        guard activity != .working else { return false }
        if let settle { return time >= settle.began + settle.duration }
        let sample = sample(at: time)
        return abs(sample.velocity) < 0.001
            && abs(sample.angle - Self.upright(sample.angle)) < 0.001
    }

    mutating func update(_ activity: Activity, at time: TimeInterval, settleDuration: TimeInterval = 0.7) {
        let current = sample(at: time)
        switch activity {
        case .working:
            guard self.activity != .working else { return }
            rotation.setAngle(current.angle / Self.angleScale, at: time)
            rotation.setRunning(true, at: time)
            settle = nil
        case .idle:
            if self.activity == .idle { return }
            let target = Self.upright(current.angle)
            rotation.setAngle(target / Self.angleScale, at: time)
            if abs(current.angle - target) > 0.001 || abs(current.velocity) > 0.001 {
                settle = Settle(began: time, duration: settleDuration, origin: current, target: target)
            } else { settle = nil }
        case .paused:
            rotation.setAngle(current.angle / Self.angleScale, at: time)
            settle = nil
        }
        self.activity = activity
    }

    private static func upright(_ angle: Double) -> Double { (angle / 360).rounded() * 360 }
}
