import AppKit
import SwiftUI
import Observation
import BopifyDomain
import BopifyPlayback
import os

@MainActor @Observable
final class MonolithWindowController {
    private(set) var layout = monolithLayout(mode: .compact, availableSize: CGSize(width: 484, height: 360))
    private(set) var contentOffset: CGPoint = .zero
    private(set) var transitionID: UInt64 = 0
    private(set) var isTransitioning = false
    private(set) var isDragging = false
    @ObservationIgnored var cancelInteraction: (() -> Bool)?
    @ObservationIgnored private weak var panel: StatusPanel?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var anchor: CGPoint?
    @ObservationIgnored private var pendingMode: (PlayerMode, Bool)?
    @ObservationIgnored private var lastRequest: (PlayerMode, Bool) = (.compact, false)
    @ObservationIgnored private var targetFrame: CGRect = .zero

    init(defaults: UserDefaults) { self.defaults = defaults }

    func attach(to panel: StatusPanel) {
        self.panel = panel
        panel.onCancelInteraction = { [weak self] in self?.cancelInteraction?() ?? false }
        anchor = Self.restoredAnchor(defaults: defaults)
        panel.minSize = CGSize(width: 1, height: 1)
        panel.maxSize = CGSize(width: 10000, height: 10000)
        panel.styleMask.remove(.resizable)
        panel.containsPlayerPoint = { [weak self] in self?.contains($0) ?? false }
    }

    func focus() { panel?.makeKey() }

    static func restoredAnchor(defaults: UserDefaults) -> CGPoint? {
        if let stored = defaults.string(forKey: "player.recordCenter"), stored.hasPrefix("{"), stored.hasSuffix("}") {
            let coordinates = stored.dropFirst().dropLast().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if coordinates.count == 2, let x = Double(coordinates[0]), let y = Double(coordinates[1]), x.isFinite, y.isFinite {
                return CGPoint(x: x, y: y)
            }
        }
        if let stored = defaults.string(forKey: "player.frame") {
            let frame = NSRectFromString(stored)
            if frame.width > 0, frame.height > 0,
               frame.midX.isFinite, frame.midY.isFinite { return CGPoint(x: frame.midX, y: frame.midY) }
        }
        return nil
    }

    func apply(mode: PlayerMode, reduceMotion: Bool, visibleFrame: CGRect? = nil) {
        guard let panel else { return }
        if isDragging { pendingMode = (mode, reduceMotion); return }
        let desiredAnchor = anchor ?? CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        let screen = NSScreen.screens.first { $0.visibleFrame.contains(desiredAnchor) } ?? panel.screen ?? NSScreen.main
        guard let visible = visibleFrame ?? screen?.visibleFrame else { return }
        var available = visible.size
        // Both lower-panel occupants reserve the same viewport before moving the spindle.
        if mode != .compact {
            available.height = min(available.height, max(300, desiredAnchor.y + 132 - visible.minY))
        }
        let next = monolithLayout(mode: mode, availableSize: available)
        let target = monolithFrame(recordCenter: desiredAnchor, layout: next, visibleFrame: visible)
        guard next != layout || target != targetFrame || (!isTransitioning && panel.frame != target) else { return }
        lastRequest = (mode, reduceMotion)
        let adjusted = CGPoint(x: target.minX + next.recordCenter.x, y: target.maxY - next.recordCenter.y)
        if adjusted != desiredAnchor { BopifyLog.playback.debug("Monolith anchor clamped to visible screen") }
        anchor = adjusted
        transitionID &+= 1
        let generation = transitionID
        targetFrame = target
        if reduceMotion || !panel.isVisible {
            isTransitioning = false
            withoutAnimation {
                layout = next
                contentOffset = .zero
                panel.setFrame(target, display: true)
            }
            persistAnchor()
            return
        }
        let oldFrame = panel.frame
        let envelope = oldFrame.union(target)
        withoutAnimation {
            contentOffset.x += oldFrame.minX - envelope.minX
            contentOffset.y += envelope.maxY - oldFrame.maxY
            panel.setFrame(envelope, display: true)
            isTransitioning = true
        }
        let duration = mode == .expanded && layout.recordDiameter == 118 ? 0.65 : 0.50
        withAnimation(.spring(duration: duration, bounce: 0.08), completionCriteria: .removed) {
            layout = next
            contentOffset = CGPoint(x: target.minX - envelope.minX, y: envelope.maxY - target.maxY)
        } completion: { [weak self] in
            self?.finishTransition(generation)
        }
    }

    func finishTransition(_ generation: UInt64) {
        guard generation == transitionID, isTransitioning, let panel else { return }
        withoutAnimation {
            panel.setFrame(targetFrame, display: true)
            contentOffset = .zero
            isTransitioning = false
        }
        persistAnchor()
    }

    func invalidateTransition() {
        transitionID &+= 1
        isTransitioning = false
        pendingMode = nil
        isDragging = false
    }

    func setDragging(_ active: Bool) {
        isDragging = active
        if active { transitionID &+= 1; isTransitioning = false }
        else {
            persistAnchor()
            let (mode, reduceMotion) = pendingMode ?? lastRequest
            pendingMode = nil
            apply(mode: mode, reduceMotion: reduceMotion)
        }
    }

    func persistAnchor() {
        guard let panel, !isTransitioning else { return }
        let point = CGPoint(x: panel.frame.minX + contentOffset.x + layout.recordCenter.x,
                            y: panel.frame.maxY - contentOffset.y - layout.recordCenter.y)
        anchor = point
        defaults.set(NSStringFromPoint(point), forKey: "player.recordCenter")
    }

    private func contains(_ point: CGPoint) -> Bool {
        let local = CGPoint(x: point.x - contentOffset.x, y: point.y - contentOffset.y)
        if hypot(local.x - layout.recordCenter.x, local.y - layout.recordCenter.y) <= layout.recordDiameter / 2 { return true }
        return !layout.sleeveFrame.isEmpty && CGPath(roundedRect: layout.sleeveFrame, cornerWidth: 28, cornerHeight: 28, transform: nil).contains(local)
    }

    private func withoutAnimation(_ body: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, body)
    }
}
