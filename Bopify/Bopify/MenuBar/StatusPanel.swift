import AppKit
import Carbon.HIToolbox
import SwiftUI

protocol PlayerShortcutForwarding {}

/// A persistent non-activating window that accepts keyboard focus when opened.
final class StatusPanel: NSPanel {
    var onDismiss: (() -> Void)?
    var onDismissPopover: (() -> Bool)?
    var onDismissQueue: (() -> Bool)?
    var onCancelInteraction: (() -> Bool)?
    var onTogglePlayback: (() -> Void)?
    var onSeek: ((Int64) -> Void)?
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    var onSearch: (() -> Void)?
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
        let host = PlayerHostingView(rootView: content)
        // The controllers own the panel frame. As the window's direct content view, NSHostingView also animates
        // the window to its content size from inside the constraints pass, one pass per step, until AppKit aborts.
        // Nesting it in a plain container keeps SwiftUI from resizing the window at all.
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        let container = NSView(frame: host.frame)
        container.addSubview(host)
        contentView = container
    }

    override var canBecomeKey: Bool { true }
    override func becomeKey() { super.becomeKey(); onKeyChanged?(true) }
    override func resignKey() { super.resignKey(); onKeyChanged?(false) }
    override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval { 0.36 }

    override func cancelOperation(_ sender: Any?) {
        if onDismissPopover?() == true { return }
        if onCancelInteraction?() == true { return }
        if onDismissQueue?() != true { onDismiss?() }
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            let point = CGPoint(x: event.locationInWindow.x, y: frame.height - event.locationInWindow.y)
            if containsPlayerPoint?(point) == true { makeKey() }
        }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == kVK_ANSI_F,
           event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
           let onSearch {
            if !event.isARepeat { onSearch() }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard !(firstResponder is NSTextView), !(firstResponder is NSControl) || firstResponder is PlayerShortcutForwarding else {
            super.keyDown(with: event)
            return
        }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch (Int(event.keyCode), modifiers) {
        case (kVK_Space, []): if !event.isARepeat { onTogglePlayback?() }
        case (kVK_LeftArrow, []): onSeek?(-5000)
        case (kVK_RightArrow, []): onSeek?(5000)
        case (kVK_LeftArrow, .command): if !event.isARepeat { onPrevious?() }
        case (kVK_RightArrow, .command): if !event.isARepeat { onNext?() }
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
    // Always forward to super: SwiftUI's onHover is driven by these same events.
    override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); updatePointer(event) }
    override func mouseMoved(with event: NSEvent) { super.mouseMoved(with: event); updatePointer(event) }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); (window as? StatusPanel)?.onPointerChanged?(false) }
    private func updatePointer(_ event: NSEvent) {
        guard let panel = window as? StatusPanel, let contains = panel.containsPlayerPoint else { return }
        let point = CGPoint(x: event.locationInWindow.x, y: panel.frame.height - event.locationInWindow.y)
        panel.onPointerChanged?(contains(point))
    }
}
