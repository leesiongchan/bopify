import AppKit
import SwiftUI
import Observation
import BopifyDomain
import BopifyPlayback
import os

@MainActor @Observable
final class PlayerWindowController {
    private(set) var layout = recordLayout(mode: .compact, availableSize: CGSize(width: 484, height: 360))
    private(set) var contentOffset: CGPoint = .zero
    private(set) var transitionID: UInt64 = 0
    private(set) var isTransitioning = false
    private(set) var isDragging = false
    @ObservationIgnored var onCancelInteraction: (() -> Bool)?
    @ObservationIgnored private weak var panel: StatusPanel?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var anchor: CGPoint?
    @ObservationIgnored private var pendingMode: (mode: PlayerMode, reduceMotion: Bool, showsLyrics: Bool)?
    @ObservationIgnored private var lastRequest: (mode: PlayerMode, reduceMotion: Bool, showsLyrics: Bool) = (.compact, false, false)
    @ObservationIgnored private var targetFrame: CGRect = .zero

    init(defaults: UserDefaults) { self.defaults = defaults }

    #if DEBUG
    /// No panel: previews render the player in a fixed frame laid out for `mode`.
    init(previewMode mode: PlayerMode) {
        defaults = UserDefaults(suiteName: "com.leesiongchan.bopify.preview.\(UUID().uuidString)")!
        layout = recordLayout(mode: mode, availableSize: CGSize(width: 484, height: 360))
    }
    #endif

    func attach(to panel: StatusPanel) {
        self.panel = panel
        // Native shadow traces the record's translucent halo as a second hard outline.
        panel.hasShadow = false
        panel.onCancelInteraction = { [weak self] in self?.onCancelInteraction?() ?? false }
        anchor = Self.restoredAnchor(defaults: defaults)
        panel.minSize = CGSize(width: 1, height: 1)
        panel.maxSize = CGSize(width: 10000, height: 10000)
        panel.styleMask.remove(.resizable)
        panel.containsPlayerPoint = { [weak self] in self?.contains($0) ?? false }
        panel.containsLyricsPoint = { [weak self] point in
            guard let self else { return false }
            let local = CGPoint(x: point.x - self.contentOffset.x, y: point.y - self.contentOffset.y)
            return self.layout.lyricsFrame.contains(local)
        }
    }

    func focus() { panel?.focusPlayer() }

    func focusLyrics() { panel?.focusLyrics(keepingPlayerExpanded: !layout.controlsFrame.isEmpty) }
    func show() { panel?.orderFrontRegardless() }

    func configureLyricsKeyboard(model: LyricRibbonModel) {
        panel?.onLyricsFocusEnded = { [weak model] in
            model?.isKeyboardInteracting = false
            model?.keyboardSelection = nil
        }
        panel?.onLyricTab = { [weak self, weak model] in
            guard let model else { return }
            model.keyboardSelection = model.isReading && model.keyboardSelection == .reader ? .sync : .reader
            if model.keyboardSelection == .reader { self?.focusLyrics() }
        }
        panel?.onLyricActivate = { [weak self, weak model] in
            guard model?.keyboardSelection == .sync else { return }
            model?.backToLive()
            self?.focusLyrics()
        }
    }

    func removeLyricsKeyboard() { panel?.removeLyricsKeyboard() }

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

    func apply(mode: PlayerMode, reduceMotion: Bool, visibleFrame: CGRect? = nil, showsLyrics: Bool = false) {
        guard let panel else { return }
        if isDragging { pendingMode = (mode, reduceMotion, showsLyrics); return }
        var desiredAnchor = anchor ?? CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        let screen = NSScreen.screens.first { $0.visibleFrame.contains(desiredAnchor) } ?? panel.screen ?? NSScreen.main
        guard let visible = visibleFrame ?? screen?.visibleFrame else { return }
        let next = recordLayout(mode: mode, availableSize: visible.size, showsLyrics: showsLyrics)
        if !layout.lyricsFrame.isEmpty, !next.lyricsFrame.isEmpty {
            desiredAnchor.x += layout.lyricsFrame.minX - layout.recordCenter.x - next.lyricsFrame.minX + next.recordCenter.x
            desiredAnchor.y += layout.recordCenter.y - layout.lyricsFrame.minY - next.recordCenter.y + next.lyricsFrame.minY
        }
        let target = playerWindowFrame(recordCenter: desiredAnchor, layout: next, visibleFrame: visible)
        guard next != layout || target != targetFrame || (!isTransitioning && panel.frame != target) else { return }
        lastRequest = (mode, reduceMotion, showsLyrics)
        let adjusted = CGPoint(x: target.minX + next.recordCenter.x, y: target.maxY - next.recordCenter.y)
        if adjusted != desiredAnchor { BopifyLog.playback.debug("Player anchor clamped to visible screen") }
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
        let hasLyrics = showsLyrics || !layout.lyricsFrame.isEmpty
        let duration = hasLyrics ? 0.40 : mode == .expanded && layout.recordDiameter == 118 ? 0.65 : 0.50
        withAnimation(.spring(duration: duration, bounce: hasLyrics ? 0.04 : 0.18),
                      completionCriteria: .removed) {
            layout = next
            contentOffset = CGPoint(x: target.minX - envelope.minX, y: envelope.maxY - target.maxY)
        } completion: { [weak self] in
            // Completion can run inside NSHostingView.layout during a Core Animation commit.
            DispatchQueue.main.async { [weak self] in self?.finishTransition(generation) }
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
            let (mode, reduceMotion, showsLyrics) = pendingMode ?? lastRequest
            pendingMode = nil
            apply(mode: mode, reduceMotion: reduceMotion, showsLyrics: showsLyrics)
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
        if !layout.lyricsFrame.isEmpty, layout.controlsFrame.isEmpty { return false }
        if hypot(local.x - layout.recordCenter.x, local.y - layout.recordCenter.y) <= layout.recordDiameter / 2 { return true }
        let radius = min(layout.sleeveCornerRadius, layout.sleeveFrame.width / 2, layout.sleeveFrame.height / 2)
        return !layout.sleeveFrame.isEmpty && CGPath(roundedRect: layout.sleeveFrame, cornerWidth: radius, cornerHeight: radius, transform: nil).contains(local)
    }

    private func withoutAnimation(_ body: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, body)
    }
}
