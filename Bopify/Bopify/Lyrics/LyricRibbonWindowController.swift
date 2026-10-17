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
        panel.makeKeyAndOrderFront(nil)
        panel.selectNextKeyView(nil)
    }

    func refreshLayout(textScale: CGFloat) {
        self.textScale = textScale
        let screens = NSScreen.screens.map(\.visibleFrame)
        let preferred = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1024, height: 768)
        let visible = Self.screen(for: anchor, screens: screens, preferred: preferred)
        let layout = LyricRibbonLayout.measure(content: model.content, width: min(448, visible.width),
            textScale: textScale, availableHeight: max(100, visible.height - 40))
        let root = LyricRibbonView(model: model, layout: layout, onHide: onHide,
            onDragHeader: { [weak self] event in self?.panel.performDrag(with: event) })
        if let host { host.rootView = root }
        else {
            let host = NSHostingView(rootView: root)
            host.sizingOptions = []
            host.autoresizingMask = [.width, .height]
            let container = NSView(frame: CGRect(origin: .zero, size: layout.panelSize))
            host.frame = container.bounds
            container.addSubview(host)
            panel.contentView = container
            self.host = host
        }
        let frame = Self.reachableFrame(saved: anchor, size: layout.panelSize, screens: screens, preferred: preferred)
        panel.setFrame(frame, display: true)
    }

    static func reachableFrame(saved: CGRect?, size: CGSize, screens: [CGRect], preferred: CGRect) -> CGRect {
        let visible = screen(for: saved, screens: screens, preferred: preferred)
        let origin: CGPoint
        if let saved, saved.origin.x.isFinite, saved.origin.y.isFinite { origin = saved.origin }
        else { origin = CGPoint(x: visible.midX - size.width / 2, y: visible.minY + 40) }
        return clampedPlayerFrame(origin: origin, size: size, visibleFrame: visible)
    }

    private static func screen(for saved: CGRect?, screens: [CGRect], preferred: CGRect) -> CGRect {
        if let saved, saved.origin.x.isFinite, saved.origin.y.isFinite,
           let screen = screens.first(where: { $0.intersects(saved) }) { return screen }
        return preferred
    }

    func windowDidMove(_ notification: Notification) { if panel.isVisible { saveFrame() } }
    func windowShouldClose(_ sender: NSWindow) -> Bool { onHide(); return false }
    @objc private func screensChanged() { refreshLayout(textScale: textScale) }

    private func saveFrame() {
        anchor = panel.frame
        defaults.set(NSStringFromRect(panel.frame), forKey: "lyrics.preview.frame")
    }
}

private final class LyricRibbonPanel: NSPanel {
    var allowsKeyboardFocus = false
    var onDismiss: (() -> Void)?
    override var canBecomeKey: Bool { allowsKeyboardFocus }
    override func resignKey() { super.resignKey(); allowsKeyboardFocus = false }
    override func cancelOperation(_ sender: Any?) { onDismiss?() }
}
#endif
