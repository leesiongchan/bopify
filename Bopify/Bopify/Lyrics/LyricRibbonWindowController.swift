import AppKit
import SwiftUI
import BopifyPlayback
import BopifyDomain
import os

final class LyricRibbonWindowController: NSObject, NSWindowDelegate {
    let panel: NSPanel
    private let model: LyricRibbonModel
    private let defaults: UserDefaults
    private let artworkStore: ArtworkStore?
    private let onHide: () -> Void
    private let onSeek: (Int64, LyricPlaybackSnapshot) -> Void
    private var host: NSHostingView<LyricRibbonView>?
    private var anchor: CGRect?
    private var textScale: CGFloat = 1
    private let position = LyricRibbonPosition()
    private var isDragging = false
    private var isPositioning = false
    private var isTransitioning = false
    private var transitionID: UInt64 = 0
    private var targetFrame: CGRect = .zero

    init(model: LyricRibbonModel, defaults: UserDefaults, artworkStore: ArtworkStore? = nil, onSeek: @escaping (Int64, LyricPlaybackSnapshot) -> Void = { _, _ in }, onHide: @escaping () -> Void) {
        self.model = model
        self.defaults = defaults
        self.artworkStore = artworkStore
        self.onHide = onHide
        self.onSeek = onSeek
        panel = LyricRibbonPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        if let value = defaults.string(forKey: "lyrics.preview.frame") {
            let rect = NSRectFromString(value)
            if !rect.isEmpty { anchor = rect }
        }
        super.init()
        panel.delegate = self
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        (panel as? LyricRibbonPanel)?.onDismiss = onHide
        (panel as? LyricRibbonPanel)?.onKeyboardInteraction = { [weak model] active in
            model?.isKeyboardInteracting = active
            if !active { model?.keyboardSelection = nil }
        }
        (panel as? LyricRibbonPanel)?.onTab = { [weak self] in
            guard let self else { return }
            if self.model.isReading, self.model.keyboardSelection == .reader { self.model.keyboardSelection = .sync }
            else { self.focusReader() }
        }
        (panel as? LyricRibbonPanel)?.onActivate = { [weak self] in
            guard let self, self.model.keyboardSelection == .sync else { return }
            self.model.backToLive()
            self.focusReader()
        }
        refreshLayout(textScale: 1)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func show() {
        model.show()
        refreshLayout(textScale: textScale)
        panel.orderFront(nil)
    }

    func hide() {
        finishTransition(transitionID)
        isDragging = false
        if panel.isVisible { saveFrame() }
        panel.orderOut(nil)
        (panel as? LyricRibbonPanel)?.allowsKeyboardFocus = false
        model.hide()
    }

    func focusForReading() {
        if !model.isVisible { show() }
        (panel as? LyricRibbonPanel)?.allowsKeyboardFocus = true
        panel.makeKeyAndOrderFront(nil)
        focusReader()
    }

    private func focusReader() {
        guard model.isKeyboardInteracting else { return }
        model.keyboardSelection = .reader
        if let reader = reader(in: panel.contentView) { panel.makeFirstResponder(reader) }
    }

    private func reader(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let text = view as? NSTextView { return text }
        return view.subviews.lazy.compactMap { self.reader(in: $0) }.first
    }

    func refreshLayout(textScale: CGFloat, animate: Bool = false) {
        self.textScale = textScale
        guard !isDragging else { return }
        finishTransition(transitionID)
        let screens = NSScreen.screens.map(\.visibleFrame)
        let preferred = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1024, height: 768)
        let placement = Self.placement(content: model.content, saved: anchor, textScale: textScale,
            screens: screens, preferred: preferred, source: model.source)
        let layout = placement.layout
        let root = LyricRibbonView(model: model, layout: layout, artworkStore: artworkStore,
            onFocusReader: { [weak self] in self?.focusReader() }, onSeek: onSeek, position: position,
            onPrepareDrag: { [weak self] in
                guard let self else { return }
                self.finishTransition(self.transitionID)
            }, onDragChanged: { [weak self] active in self?.setDragging(active) })
        if let host { host.rootView = root }
        else {
            let host = LyricRibbonHostingView(rootView: root)
            host.sizingOptions = []
            host.autoresizingMask = [.width, .height]
            let container = NSView(frame: CGRect(origin: .zero, size: layout.panelSize))
            host.frame = container.bounds
            container.addSubview(host)
            panel.contentView = container
            self.host = host
        }
        move(to: placement.frame, animated: animate && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    func setDragging(_ active: Bool) {
        isDragging = active
        if active {
            BopifyLog.playback.debug("Lyric ribbon drag started")
        } else {
            anchor = panel.frame
            refreshLayout(textScale: textScale, animate: true)
            BopifyLog.playback.debug("Lyric ribbon drag ended")
        }
    }

    private func move(to target: CGRect, animated: Bool) {
        transitionID &+= 1
        let generation = transitionID
        targetFrame = target
        guard animated, panel.isVisible, panel.frame != target else {
            isPositioning = true
            panel.setFrame(target, display: true)
            isPositioning = false
            if panel.isVisible { saveFrame() }
            return
        }
        let old = panel.frame
        let envelope = old.union(target)
        isTransitioning = true
        withoutAnimation {
            position.offset = CGPoint(x: old.minX - envelope.minX, y: envelope.maxY - old.maxY)
            panel.setFrame(envelope, display: true)
        }
        BopifyLog.playback.debug("Lyric ribbon clamped to visible screen")
        withAnimation(.spring(duration: 0.50, bounce: 0.18), completionCriteria: .removed) {
            position.offset = CGPoint(x: target.minX - envelope.minX, y: envelope.maxY - target.maxY)
        } completion: { [weak self] in
            DispatchQueue.main.async { [weak self] in self?.finishTransition(generation) }
        }
    }

    private func finishTransition(_ generation: UInt64) {
        guard generation == transitionID, isTransitioning else { return }
        transitionID &+= 1
        withoutAnimation {
            panel.setFrame(targetFrame, display: true)
            position.offset = .zero
        }
        isTransitioning = false
        if panel.isVisible { saveFrame() }
    }

    private func withoutAnimation(_ body: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, body)
    }

    static func placement(content: LyricContent, saved: CGRect?, textScale: CGFloat,
                          screens: [CGRect], preferred: CGRect, source: LyricSourceMetadata? = nil) -> (layout: LyricRibbonLayout, frame: CGRect) {
        let visible = screen(for: saved, screens: screens, preferred: preferred)
        let layout = LyricRibbonLayout.measure(content: content, width: min(448, visible.width),
            textScale: textScale, availableHeight: max(100, visible.height - 40), source: source)
        return (layout, reachableFrame(saved: saved, size: layout.panelSize, screens: screens, preferred: preferred))
    }

    static func reachableFrame(saved: CGRect?, size: CGSize, screens: [CGRect], preferred: CGRect) -> CGRect {
        let visible = screen(for: saved, screens: screens, preferred: preferred)
        let origin: CGPoint
        if let saved, saved.origin.x.isFinite, saved.origin.y.isFinite { origin = saved.origin }
        else { origin = CGPoint(x: visible.midX - size.width / 2, y: visible.minY + 40) }
        return clampedPlayerFrame(origin: origin, size: size, visibleFrame: visible)
    }

    private static func screen(for saved: CGRect?, screens: [CGRect], preferred: CGRect) -> CGRect {
        if let saved, saved.origin.x.isFinite, saved.origin.y.isFinite {
            let overlaps = screens.map { screen in
                let intersection = screen.intersection(saved)
                return (screen, intersection.isNull ? 0 : intersection.width * intersection.height)
            }
            if let largest = overlaps.filter({ $0.1 > 0 }).max(by: { $0.1 < $1.1 }) { return largest.0 }
        }
        return preferred
    }

    func windowDidMove(_ notification: Notification) {
        if panel.isVisible && !isDragging && !isTransitioning && !isPositioning { saveFrame() }
    }
    func windowDidChangeScreen(_ notification: Notification) {
        guard panel.isVisible, !isDragging, !isTransitioning, !isPositioning else { return }
        anchor = panel.frame
        refreshLayout(textScale: textScale)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { onHide(); return false }
    @objc private func screensChanged() { refreshLayout(textScale: textScale) }

    private func saveFrame() {
        anchor = panel.frame
        defaults.set(NSStringFromRect(panel.frame), forKey: "lyrics.preview.frame")
    }
}

private final class LyricRibbonPanel: NSPanel {
    var allowsKeyboardFocus = false { didSet { onKeyboardInteraction?(allowsKeyboardFocus) } }
    var onKeyboardInteraction: ((Bool) -> Void)?
    var onDismiss: (() -> Void)?
    var onTab: (() -> Void)?
    var onActivate: (() -> Void)?
    override var canBecomeKey: Bool { allowsKeyboardFocus }
    override func resignKey() { super.resignKey(); allowsKeyboardFocus = false }
    override func cancelOperation(_ sender: Any?) { onDismiss?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 48 { onTab?(); return }
        if event.keyCode == 49 || event.keyCode == 36 { onActivate?(); return }
        super.keyDown(with: event)
    }

}

private final class LyricRibbonHostingView: NSHostingView<LyricRibbonView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func keyDown(with event: NSEvent) {
        if [48, 49, 36].contains(event.keyCode) { window?.keyDown(with: event); return }
        super.keyDown(with: event)
    }
}
