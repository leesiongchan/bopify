import AppKit
import SwiftUI

struct PlayerBackgroundDragRegion: NSViewRepresentable {
    var takesKeyboardFocus = true
    var onPrepareDrag: () -> Void = {}
    var onDragChanged: ((Bool) -> Void)? = nil
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {
        nsView.takesKeyboardFocus = takesKeyboardFocus
        nsView.onPrepareDrag = onPrepareDrag
        nsView.onDragChanged = onDragChanged
    }

    final class DragView: NSView {
        var takesKeyboardFocus = true
        var onPrepareDrag: () -> Void = {}
        var onDragChanged: ((Bool) -> Void)?
        private var start: CGPoint?
        private var origin: CGPoint = .zero
        private var isDragging = false
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            let screenPoint = window?.convertPoint(toScreen: event.locationInWindow)
            onPrepareDrag()
            if takesKeyboardFocus { window?.makeKey() }
            start = screenPoint
            origin = window?.frame.origin ?? .zero
        }
        override func mouseDragged(with event: NSEvent) {
            guard let start, let panel = window else { return }
            let point = panel.convertPoint(toScreen: event.locationInWindow)
            let delta = CGPoint(x: point.x - start.x, y: point.y - start.y)
            guard isDragging || hypot(delta.x, delta.y) > 4 else { return }
            if !isDragging { isDragging = true; notifyDragging(true) }
            panel.setFrameOrigin(CGPoint(x: origin.x + delta.x, y: origin.y + delta.y))
        }
        override func mouseUp(with event: NSEvent) { endDrag() }
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { endDrag() }
            super.viewWillMove(toWindow: newWindow)
        }
        private func endDrag() {
            start = nil
            if isDragging { isDragging = false; notifyDragging(false) }
        }
        private func notifyDragging(_ active: Bool) {
            if let onDragChanged { onDragChanged(active) }
            else { (window as? StatusPanel)?.onWindowDragChanged?(active) }
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
