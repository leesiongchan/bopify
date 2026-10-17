#if DEBUG
import AppKit
import SwiftUI
import BopifyPlayback

final class LyricRibbonWindowController: NSObject, NSWindowDelegate {
    let panel: NSPanel
    private let model: LyricRibbonModel
    private let defaults: UserDefaults
    private let onHide: () -> Void
    private var host: NSHostingView<LyricRibbonView>?
    private var anchor: CGRect?
    private var textScale: CGFloat = 1

    init(model: LyricRibbonModel, defaults: UserDefaults, onHide: @escaping () -> Void) {
        self.model = model
        self.defaults = defaults
        self.onHide = onHide
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
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        (panel as? LyricRibbonPanel)?.onDismiss = onHide
        (panel as? LyricRibbonPanel)?.onKeyboardInteraction = { [weak model] active in
            model?.isKeyboardInteracting = active
            if !active { model?.keyboardSelection = nil }
        }
        (panel as? LyricRibbonPanel)?.onTab = { [weak self] in
            guard let self else { return }
            self.model.keyboardSelection = self.canRead && self.model.keyboardSelection != .reading ? .reading : .hide
        }
        (panel as? LyricRibbonPanel)?.onActivate = { [weak self] in
            guard let self else { return }
            if self.model.keyboardSelection == .hide { self.onHide() }
            else if self.model.isHeld { self.model.backToLive() }
            else { self.model.holdText() }
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
        if panel.isVisible { saveFrame() }
        panel.orderOut(nil)
        (panel as? LyricRibbonPanel)?.allowsKeyboardFocus = false
        model.hide()
    }

    func focusForReading() {
        if !model.isVisible { show() }
        (panel as? LyricRibbonPanel)?.allowsKeyboardFocus = true
        model.keyboardSelection = canRead ? .reading : .hide
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(panel)
    }

    private var canRead: Bool { model.isHeld || model.projection?.interval == .cue }

    func refreshLayout(textScale: CGFloat) {
        self.textScale = textScale
        if model.isKeyboardInteracting, !canRead { model.keyboardSelection = .hide }
        let screens = NSScreen.screens.map(\.visibleFrame)
        let preferred = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1024, height: 768)
        let placement = Self.placement(content: model.content, saved: anchor, textScale: textScale,
            screens: screens, preferred: preferred)
        let layout = placement.layout
        let root = LyricRibbonView(model: model, layout: layout, onHide: onHide,
            onDragHeader: { [weak self] event in self?.panel.performDrag(with: event) })
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
        panel.setFrame(placement.frame, display: true)
    }

    static func placement(content: LyricContent, saved: CGRect?, textScale: CGFloat,
                          screens: [CGRect], preferred: CGRect) -> (layout: LyricRibbonLayout, frame: CGRect) {
        let visible = screen(for: saved, screens: screens, preferred: preferred)
        let layout = LyricRibbonLayout.measure(content: content, width: min(448, visible.width),
            textScale: textScale, availableHeight: max(100, visible.height - 40))
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

    func windowDidMove(_ notification: Notification) { if panel.isVisible { saveFrame() } }
    func windowDidChangeScreen(_ notification: Notification) {
        guard panel.isVisible else { return }
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
        let modifiers = event.modifierFlags.intersection([.command, .option, .control])
        if allowsKeyboardFocus, modifiers.isEmpty {
            if event.keyCode == 48 { onTab?(); return }
            if event.keyCode == 49 || event.keyCode == 36 {
                if !event.isARepeat { onActivate?() }
                return
            }
        }
        super.keyDown(with: event)
    }
}

private final class LyricRibbonHostingView: NSHostingView<LyricRibbonView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
#endif
