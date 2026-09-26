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
        contentView = NSHostingView(rootView: content)
    }

    override var canBecomeKey: Bool { true }
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

struct WindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}

    final class DragView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}
