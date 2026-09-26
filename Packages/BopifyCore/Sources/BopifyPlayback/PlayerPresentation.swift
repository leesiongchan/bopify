import Foundation
import CoreGraphics
import Observation
import BopifyDomain

public enum PlayerMode: String, Codable, Sendable { case expanded, compact, queue }

@MainActor
@Observable
public final class PlayerPresentation {
    public private(set) var mode: PlayerMode
    public var keepOnTop: Bool
    public var isVisible = false

    public init(mode: PlayerMode = .expanded, keepOnTop: Bool = false) {
        self.mode = mode
        self.keepOnTop = keepOnTop
    }
    public func setMode(_ mode: PlayerMode) { self.mode = mode }
    public func dismissQueue() -> Bool {
        guard mode == .queue else { return false }
        mode = .expanded
        return true
    }
}

public enum CarouselDirection: Sendable { case next, previous, fade }

public func carouselDirection(old: PlaybackQueue?, new: PlaybackQueue) -> CarouselDirection {
    guard let old, let before = old.current?.id, let after = new.current?.id,
          before != after else { return .fade }
    if old.next.first?.id == after && new.previous.last?.id == before { return .next }
    if old.previous.last?.id == after && new.next.first?.id == before { return .previous }
    return .fade
}

public func radialProgress(x: Double, y: Double) -> Double? {
    guard x.isFinite, y.isFinite, x != 0 || y != 0 else { return nil }
    let turns = (atan2(y, x) - .pi / 2) / (2 * .pi)
    return turns < 0 ? turns + 1 : turns
}

public func shouldAdvanceAlbum(translation: CGSize, diameter: CGFloat) -> Bool {
    translation.width <= -diameter * 0.25 && abs(translation.height) < -translation.width
}

public struct RadialScrub {
    private var previous: Double
    private var unwrapped: Double
    public var progress: Double { min(1, max(0, unwrapped)) }
    public init(start: Double) {
        previous = start.isFinite ? min(1, max(0, start)) : 0
        unwrapped = previous
    }
    public mutating func update(_ fraction: Double) {
        guard fraction.isFinite else { return }
        var delta = fraction - previous
        if delta > 0.5 { delta -= 1 }
        if delta < -0.5 { delta += 1 }
        unwrapped += delta
        previous = fraction
    }
}

public func seekPosition(progress: Double, durationMs: Int64) -> Int64? {
    guard progress.isFinite, durationMs > 0 else { return nil }
    let value = (Double(durationMs) * min(1, max(0, progress))).rounded()
    return min(durationMs, Int64(clamping: UInt64(value)))
}

public func clampedPlayerFrame(origin: CGPoint, size: CGSize, visibleFrame: CGRect) -> CGRect {
    guard !visibleFrame.isEmpty else { return .zero }
    let width = min(visibleFrame.width, max(0, size.width.isFinite ? size.width : 410))
    let height = min(visibleFrame.height, max(0, size.height.isFinite ? size.height : 560))
    let x = origin.x.isFinite ? origin.x : visibleFrame.minX
    let y = origin.y.isFinite ? origin.y : visibleFrame.minY
    return CGRect(x: min(max(x, visibleFrame.minX), visibleFrame.maxX - width),
                  y: min(max(y, visibleFrame.minY), visibleFrame.maxY - height),
                  width: width, height: height)
}
