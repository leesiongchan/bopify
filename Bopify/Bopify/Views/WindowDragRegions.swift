import AppKit
import SwiftUI

struct PlayerBackgroundDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}

    final class DragView: NSView {
        private var start: CGPoint?
        private var origin: CGPoint = .zero
        private var isDragging = false
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
            guard isDragging || hypot(delta.x, delta.y) > 4 else { return }
            if !isDragging { isDragging = true; panel.onWindowDragChanged?(true) }
            panel.setFrameOrigin(CGPoint(x: origin.x + delta.x, y: origin.y + delta.y))
        }
        override func mouseUp(with event: NSEvent) { endDrag() }
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { endDrag() }
            super.viewWillMove(toWindow: newWindow)
        }
        private func endDrag() {
            start = nil
            if isDragging { isDragging = false; (window as? StatusPanel)?.onWindowDragChanged?(false) }
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
