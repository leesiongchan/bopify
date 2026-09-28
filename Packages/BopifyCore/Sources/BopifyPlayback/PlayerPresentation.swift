import Foundation
import CoreGraphics
import Observation
import BopifyDomain
import os

public enum PlayerPopover: Sendable { case favorite, volume }

public enum PlayerMode: String, Codable, Sendable { case expanded, compact, queue }

@MainActor
@Observable
public final class PlayerPresentation {
    public private(set) var activePopover: PlayerPopover?
    public private(set) var mode: PlayerMode
    public var keepOnTop: Bool
    public var isVisible: Bool {
        get { attention.isVisible }
        set { sendAttention(.visibility(newValue)) }
    }
    private var attention = PlayerAttentionState()
    private var queueRequested = false
    @ObservationIgnored private var collapseTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    public init(mode: PlayerMode = .expanded, keepOnTop: Bool = false) {
        self.mode = mode
        self.keepOnTop = keepOnTop
    }
    public func setMode(_ mode: PlayerMode) {
        queueRequested = mode == .queue
        self.mode = mode
    }
    public func sendAttention(_ event: PlayerAttentionEvent) {
        switch event {
        case .visibility(false), .reset: activePopover = nil
        default: break
        }
        attention.update(event, at: ProcessInfo.processInfo.systemUptime)
        updateMode()
        scheduleCollapse()
    }
    public func presentPopover(_ popover: PlayerPopover) {
        guard isVisible else { return }
        activePopover = popover
        sendAttention(.interaction(.popover, true))
    }
    @discardableResult public func dismissPopover() -> Bool {
        guard activePopover != nil else { return false }
        activePopover = nil
        sendAttention(.interaction(.popover, false))
        return true
    }
    public func requestQueue(_ open: Bool) {
        queueRequested = open && attention.isRevealed
        updateMode()
    }
    public func resetEngagement() { sendAttention(.reset) }
    func advanceAttention(to now: TimeInterval) {
        attention.advance(to: now)
        updateMode()
        scheduleCollapse()
    }
    private func updateMode() {
        if !attention.isRevealed { queueRequested = false }
        let next: PlayerMode = attention.isRevealed ? (queueRequested ? .queue : .expanded) : .compact
        guard next != mode else { return }
        mode = next
        BopifyLog.playback.debug("Player presentation: \(next.rawValue, privacy: .public)")
    }
    private func scheduleCollapse() {
        collapseTask?.cancel()
        collapseTask = nil
        generation += 1
        guard let deadline = attention.collapseDeadline else { return }
        let expectedGeneration = generation
        let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        collapseTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.generation == expectedGeneration else { return }
            self.advanceAttention(to: ProcessInfo.processInfo.systemUptime)
        }
    }
    public func dismissQueue() -> Bool {
        guard mode == .queue else { return false }
        queueRequested = false
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
    let turns = (atan2(y, x) + .pi / 2) / (2 * .pi)
    return turns < 0 ? turns + 1 : turns
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

/// What the expanded player shows. It lives here, not in the view, so its
/// precedence is tested: startup must never flash the paste view.
public enum PlayerContent: Equatable, Sendable {
    case player, loading, remote(deviceName: String), chooseContext

    public init(_ state: PlaybackState) {
        guard state.currentTrack == nil else { self = .player; return }
        switch state.phase {
        case .error: self = .player
        case .loading, .buffering: self = .loading
        default:
            switch state.startup {
            case .pending, .resolved(.restored), .resolved(.likedSongs): self = .loading
            case let .resolved(.remote(deviceName)): self = .remote(deviceName: deviceName)
            case .resolved(.nothing): self = state.phase == .idle ? .chooseContext : .player
            }
        }
    }
}

/// What the status line says while Bopify is not the active device.
public enum InactiveStatus: Equatable, Sendable {
    case playingOn(deviceName: String), pausedOn(deviceName: String), notPlaying

    public init(_ state: PlaybackState) {
        guard let remote = state.remote else { self = .notPlaying; return }
        self = remote.isPlaying ? .playingOn(deviceName: remote.deviceName) : .pausedOn(deviceName: remote.deviceName)
    }
}
