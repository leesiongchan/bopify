import AppKit
import SwiftUI

/// A persistent non-activating window that accepts keyboard focus when opened.
final class StatusPanel: NSPanel {
    var onDismiss: (() -> Void)?
    var onDismissQueue: (() -> Bool)?
    var onTogglePlayback: (() -> Void)?
    var onSeek: ((Int64) -> Void)?
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    var onKeyChanged: ((Bool) -> Void)?
    var onPointerChanged: ((Bool) -> Void)?
    var onWindowDragChanged: ((Bool) -> Void)?
    var containsPlayerPoint: ((CGPoint) -> Bool)?

    init<Content: View>(content: Content) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 410, height: 560),
                   styleMask: [.borderless, .nonactivatingPanel, .resizable],
                   backing: .buffered, defer: false)
        isFloatingPanel = false
        level = .normal
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isMovable = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        acceptsMouseMovedEvents = true
        contentView = PlayerHostingView(rootView: content)
    }

    override var canBecomeKey: Bool { true }
    override func becomeKey() { super.becomeKey(); onKeyChanged?(true) }
    override func resignKey() { super.resignKey(); onKeyChanged?(false) }
    override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval { 0.36 }

    override func cancelOperation(_ sender: Any?) {
        if onDismissQueue?() != true { onDismiss?() }
    }

    override func keyDown(with event: NSEvent) {
        guard !(firstResponder is NSTextView), !(firstResponder is NSControl) else {
            super.keyDown(with: event)
            return
        }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch (event.keyCode, modifiers) {
        case (49, []): if !event.isARepeat { onTogglePlayback?() }
        case (123, []): onSeek?(-5000)
        case (124, []): onSeek?(5000)
        case (123, .command): if !event.isARepeat { onPrevious?() }
        case (124, .command): if !event.isARepeat { onNext?() }
        default: super.keyDown(with: event)
        }
    }
}

private final class PlayerHostingView<Content: View>: NSHostingView<Content> {
    private var playerTrackingArea: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let playerTrackingArea { removeTrackingArea(playerTrackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect], owner: self)
        addTrackingArea(area)
        playerTrackingArea = area
    }
    override func mouseEntered(with event: NSEvent) { updatePointer(event) }
    override func mouseMoved(with event: NSEvent) { updatePointer(event) }
    override func mouseExited(with event: NSEvent) { (window as? StatusPanel)?.onPointerChanged?(false) }
    private func updatePointer(_ event: NSEvent) {
        guard let panel = window as? StatusPanel, let contains = panel.containsPlayerPoint else { return }
        let point = CGPoint(x: event.locationInWindow.x, y: panel.frame.height - event.locationInWindow.y)
        panel.onPointerChanged?(contains(point))
    }
}

struct RecordDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}

    final class DragView: NSView {
        private var start: CGPoint?
        private var origin: CGPoint = .zero
        private var dragging = false
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            window?.makeKey()
            start = window?.convertPoint(toScreen: event.locationInWindow)
            origin = window?.frame.origin ?? .zero
        }
        override func mouseDragged(with event: NSEvent) {
            guard let start, let panel = window as? StatusPanel else { return }
            let point = panel.convertPoint(toScreen: event.locationInWindow)
            let delta = CGPoint(x: point.x - start.x, y: point.y - start.y)
            guard dragging || hypot(delta.x, delta.y) > 4 else { return }
            if !dragging { dragging = true; panel.onWindowDragChanged?(true) }
            panel.setFrameOrigin(CGPoint(x: origin.x + delta.x, y: origin.y + delta.y))
        }
        override func mouseUp(with event: NSEvent) { endDrag() }
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { endDrag() }
            super.viewWillMove(toWindow: newWindow)
        }
        private func endDrag() {
            start = nil
            if dragging { dragging = false; (window as? StatusPanel)?.onWindowDragChanged?(false) }
        }
    }
}

struct WindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}

    final class DragView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}
