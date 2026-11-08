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
    private(set) var recordPresentationScale: CGFloat = 1
    private(set) var onboardingContentOffset: CGPoint = .zero
    private(set) var onboardingHandoff: OnboardingHandoffGeometry?
    private(set) var onboardingProgress: CGFloat = 0
    private(set) var transitionID: UInt64 = 0
    private(set) var isTransitioning = false
    private(set) var isDragging = false
    @ObservationIgnored var onCancelInteraction: (() -> Bool)?
    @ObservationIgnored private weak var panel: StatusPanel?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var anchor: CGPoint?
    @ObservationIgnored private var pendingMode: (mode: PlayerMode, animated: Bool, showsLyrics: Bool)?
    @ObservationIgnored private var lastRequest: (mode: PlayerMode, animated: Bool, showsLyrics: Bool) = (.compact, true, false)
    @ObservationIgnored private var targetFrame: CGRect = .zero
    @ObservationIgnored private var onboardingFrame: CGRect?
    @ObservationIgnored private var onboardingRecord: CGRect?
    @ObservationIgnored private var onboardingID: UUID?
    @ObservationIgnored private var onOnboardingSettled: ((UUID) -> Void)?

    init(defaults: UserDefaults) { self.defaults = defaults }

    #if DEBUG
    /// No panel: previews render the player in a fixed frame laid out for `mode`.
    init(previewMode mode: PlayerMode) {
        defaults = UserDefaults(suiteName: "com.leesiongchan.bopify.preview.\(UUID().uuidString)")!
        layout = recordLayout(mode: mode, availableSize: CGSize(width: 484, height: 360))
    }
    #endif

    func attach(to panel: StatusPanel, onboardingRecordFrame: CGRect? = nil,
                onboardingID: UUID? = nil, onOnboardingSettled: ((UUID) -> Void)? = nil) {
        self.panel = panel
        self.onboardingID = onboardingID
        self.onOnboardingSettled = onOnboardingSettled
        onboardingRecord = nil
        onboardingHandoff = nil
        onboardingProgress = 0
        // Native shadow traces the record's translucent halo as a second hard outline.
        panel.hasShadow = false
        panel.onCancelInteraction = { [weak self] in self?.onCancelInteraction?() ?? false }
        if let record = onboardingRecordFrame, record.width > 0, record.height > 0,
           record.midX.isFinite, record.midY.isFinite {
            anchor = CGPoint(x: panel.frame.minX + record.midX, y: panel.frame.maxY - record.midY)
            onboardingFrame = panel.frame
            onboardingRecord = record
            withoutAnimation {
                contentOffset = CGPoint(x: record.midX - layout.recordCenter.x, y: record.midY - layout.recordCenter.y)
                recordPresentationScale = record.width / layout.recordDiameter
                onboardingContentOffset = .zero
            }
        } else {
            anchor = Self.restoredAnchor(defaults: defaults)
            onboardingFrame = nil
            withoutAnimation {
                contentOffset = .zero
                recordPresentationScale = 1
                onboardingContentOffset = .zero
            }
        }
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

    func hide() {
        settleOnboardingHandoff()
        persistAnchor()
        invalidateTransition()
        panel?.orderOut(nil)
    }

    func settleOnboardingHandoff() {
        guard onboardingHandoff != nil else { return }
        pendingMode = nil
        finishTransition(transitionID)
    }

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

    func apply(mode: PlayerMode, animated: Bool = true, visibleFrame: CGRect? = nil, showsLyrics: Bool = false) {
        guard let panel else { return }
        if onboardingHandoff != nil {
            if !animated || !panel.isVisible { settleOnboardingHandoff() }
            else {
                pendingMode = lastRequest != (mode, animated, showsLyrics) ? (mode, animated, showsLyrics) : nil
                return
            }
        }
        if isDragging { pendingMode = (mode, animated, showsLyrics); return }
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
        lastRequest = (mode, animated, showsLyrics)
        let adjusted = CGPoint(x: target.minX + next.recordCenter.x, y: target.maxY - next.recordCenter.y)
        if adjusted != desiredAnchor { BopifyLog.playback.debug("Player anchor clamped to visible screen") }
        anchor = adjusted
        transitionID &+= 1
        let generation = transitionID
        targetFrame = target
        if let record = onboardingRecord, let sourceWindow = onboardingFrame {
            beginOnboardingHandoff(record: record, sourceWindow: sourceWindow, target: target,
                                   layout: next, animated: animated, generation: generation)
            return
        }
        if !animated || !panel.isVisible {
            isTransitioning = false
            withoutAnimation {
                layout = next
                contentOffset = .zero
                recordPresentationScale = 1
                updateOnboardingOffset(in: target)
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
            updateOnboardingOffset(in: envelope)
            panel.setFrame(envelope, display: true)
            isTransitioning = true
        }
        let hasLyrics = showsLyrics || !layout.lyricsFrame.isEmpty
        let duration = hasLyrics ? 0.40 : mode == .expanded && layout.recordDiameter == 118 ? 0.65 : 0.50
        withAnimation(.spring(duration: duration, bounce: hasLyrics ? 0.04 : 0.18),
                      completionCriteria: .removed) {
            layout = next
            contentOffset = CGPoint(x: target.minX - envelope.minX, y: envelope.maxY - target.maxY)
            recordPresentationScale = 1
        } completion: { [weak self] in
            // Completion can run inside NSHostingView.layout during a Core Animation commit.
            DispatchQueue.main.async { [weak self] in self?.finishTransition(generation) }
        }
    }

    private func beginOnboardingHandoff(record: CGRect, sourceWindow: CGRect, target: CGRect,
                                        layout next: RecordLayout, animated: Bool, generation: UInt64) {
        guard let panel else { return }
        let envelope = sourceWindow.union(target)
        let offset = CGPoint(x: target.minX - envelope.minX, y: envelope.maxY - target.maxY)
        let source = record.offsetBy(dx: sourceWindow.minX - envelope.minX, dy: envelope.maxY - sourceWindow.maxY)
        let destination = CGRect(x: offset.x + next.recordCenter.x - next.recordDiameter / 2,
                                 y: offset.y + next.recordCenter.y - next.recordDiameter / 2,
                                 width: next.recordDiameter, height: next.recordDiameter)
        withoutAnimation {
            layout = next
            contentOffset = offset
            recordPresentationScale = 1
            updateOnboardingOffset(in: envelope)
            onboardingHandoff = OnboardingHandoffGeometry(id: onboardingID ?? UUID(), source: source,
                                                         destination: destination)
            onboardingProgress = 0
            panel.setFrame(envelope, display: true)
            isTransitioning = true
        }
        guard animated, panel.isVisible else { finishTransition(generation); return }
        // Stage the measured source before starting the single coordinated timeline.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.transitionID == generation, self.onboardingHandoff != nil else { return }
            // Each visual track supplies its own easing; ease the shared clock only once.
            withAnimation(.linear(duration: 0.65),
                          completionCriteria: .removed) {
                self.onboardingProgress = 1
            } completion: { [weak self] in
                DispatchQueue.main.async { [weak self] in self?.finishTransition(generation) }
            }
        }
    }

    func finishTransition(_ generation: UInt64) {
        guard generation == transitionID, isTransitioning, let panel else { return }
        let finished = onboardingHandoff?.id
        let completion = onOnboardingSettled
        let pending = pendingMode
        withoutAnimation {
            panel.setFrame(targetFrame, display: true)
            contentOffset = .zero
            updateOnboardingOffset(in: targetFrame)
            isTransitioning = false
            onboardingHandoff = nil
            onboardingRecord = nil
            onboardingID = nil
            onOnboardingSettled = nil
            pendingMode = nil
        }
        persistAnchor()
        if let finished { completion?(finished) }
        if finished != nil, let pending {
            apply(mode: pending.mode, animated: pending.animated, showsLyrics: pending.showsLyrics)
        }
    }

    func invalidateTransition() {
        transitionID &+= 1
        onboardingHandoff = nil
        onboardingRecord = nil
        onboardingID = nil
        onOnboardingSettled = nil
        isTransitioning = false
        pendingMode = nil
        isDragging = false
    }

    func setDragging(_ active: Bool) {
        isDragging = active
        if active { transitionID &+= 1; isTransitioning = false }
        else {
            persistAnchor()
            let (mode, animated, showsLyrics) = pendingMode ?? lastRequest
            pendingMode = nil
            apply(mode: mode, animated: animated, showsLyrics: showsLyrics)
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

    private func updateOnboardingOffset(in frame: CGRect) {
        guard let source = onboardingFrame else { return }
        onboardingContentOffset = CGPoint(x: source.minX - frame.minX, y: frame.maxY - source.maxY)
    }
}
