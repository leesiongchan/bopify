import Foundation
import SwiftUI

/// Placement of one cover at a fractional distance (in covers) from the strip's position.
public struct CoverFlowTransform: Equatable, Sendable {
    public let offset: Double
    public let rotation: Double
    public let scale: Double
    public let opacity: Double
    public let zIndex: Double
}

public enum CoverFlowMotion {
    public static let spacing = 44.0

    /// Apple's scroll-view projection (WWDC18 "Designing Fluid Interfaces"); 0.998 is the standard deceleration.
    public static func projectedDistance(velocity: Double, decelerationRate: Double = 0.998) -> Double {
        velocity / 1000 * decelerationRate / (1 - decelerationRate)
    }

    /// The cover a release at `velocity` (covers per second) comes to rest on.
    public static func restingIndex(position: Double, velocity: Double, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let projected = (position + projectedDistance(velocity: velocity)).rounded()
        return Int(min(Double(count - 1), max(0, projected)))
    }

    public static func rubberBanded(_ position: Double, count: Int, resistance: Double = 0.3) -> Double {
        let upper = Double(max(0, count - 1))
        if position < 0 { return position * resistance }
        if position > upper { return upper + (position - upper) * resistance }
        return position
    }

    /// One wheel notch moves exactly one cover; a negative delta advances.
    public static func wheelTarget(from index: Int, delta: Double, count: Int) -> Int {
        guard delta != 0, count > 0 else { return index }
        return min(count - 1, max(0, index + (delta < 0 ? 1 : -1)))
    }

    /// Coarse smoothed-wheel deltas move the spring's target, not the covers, so the spring glides between events.
    public static func glideTarget(from target: Double, delta: Double, count: Int) -> Double {
        min(Double(max(0, count - 1)), max(0, target - delta / spacing))
    }

    /// Continuous in `distance`, so covers turn smoothly as they cross the center at any speed.
    /// Covers fade out by `reach`, the distance in covers to the strip's edge, so a wider strip shows more of them.
    public static func transform(distance: Double, reduceMotion: Bool, reach: Double = 3) -> CoverFlowTransform {
        let side = min(1, max(-1, distance))
        // Stretches the fade past the first side cover so it ends at `reach` rather than three covers out.
        let far = abs(distance) <= 1 ? abs(distance) : 1 + (abs(distance) - 1) * 2 / (max(2, reach) - 1)
        let opacity = far <= 1 ? 1 : far <= 2 ? 1 - 0.45 * (far - 1) : max(0, 0.55 * (3 - far))
        return CoverFlowTransform(offset: distance * spacing, rotation: reduceMotion ? 0 : -48 * side,
                                  scale: 1 - 0.2 * abs(side), opacity: opacity, zIndex: -far)
    }
}

/// Release velocity from the last 80 ms of samples, so a pause before letting go leaves no fling.
public struct CoverFlowVelocity: Sendable {
    private var samples: [(time: TimeInterval, position: Double)] = []
    public init() {}

    public mutating func add(position: Double, at time: TimeInterval) {
        samples.append((time, position))
        samples.removeAll { $0.time < time - 0.08 }
    }

    public mutating func reset() { samples.removeAll() }

    /// Covers per second.
    public var velocity: Double {
        guard let first = samples.first, let last = samples.last, last.time > first.time else { return 0 }
        return (last.position - first.position) / (last.time - first.time)
    }
}

/// Keeps the spring's current position and velocity available so motion can be grabbed mid-flight.
public struct CoverFlowSpring: Equatable, Sendable {
    public var position: Double
    public var velocity: Double
    public var target: Double

    public init(position: Double, velocity: Double, target: Double) {
        self.position = position
        self.velocity = velocity
        self.target = target
    }

    public var isSettled: Bool { position == target && velocity == 0 }

    public mutating func step(dt: Double, reduceMotion: Bool) {
        guard dt > 0, !isSettled else { return }
        // Reduce Motion: quicker and critically damped, never overshooting.
        let spring = Spring(response: reduceMotion ? 0.2 : 0.35, dampingRatio: reduceMotion ? 1 : 0.85)
        spring.update(value: &position, velocity: &velocity, target: target, deltaTime: dt)
        if abs(position - target) < 0.0005 && abs(velocity) < 0.005 {
            position = target
            velocity = 0
        }
    }
}
