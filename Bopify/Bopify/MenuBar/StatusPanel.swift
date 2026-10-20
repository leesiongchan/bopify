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
    var onShowShortcuts: (() -> Void)?
    var onKeyChanged: ((Bool) -> Void)?
    var onPointerChanged: ((Bool) -> Void)?
    var onWindowDragChanged: ((Bool) -> Void)?
    var containsPlayerPoint: ((CGPoint) -> Bool)?
    var containsLyricsPoint: ((CGPoint) -> Bool)?
    var onLyricTab: (() -> Void)?
    var onLyricActivate: (() -> Void)?
    var onLyricsFocusEnded: (() -> Void)?
    private var isHandlingPassiveLyrics = false
    private var isFocusingLyrics = false
    private var lyricFocusKeepsPlayerExpanded = false

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

    override var canBecomeKey: Bool { !isHandlingPassiveLyrics }
    override func becomeKey() { super.becomeKey(); onKeyChanged?(!isFocusingLyrics || lyricFocusKeepsPlayerExpanded) }
    override func resignKey() { super.resignKey(); endLyricsFocus(); onKeyChanged?(false) }
    override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval { 0.36 }

    override func cancelOperation(_ sender: Any?) {
        if onDismissPopover?() == true { return }
        if onCancelInteraction?() == true { return }
        if onDismissQueue?() != true { onDismiss?() }
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            let point = CGPoint(x: event.locationInWindow.x, y: frame.height - event.locationInWindow.y)
            if containsLyricsPoint?(point) == true {
                lyricFocusKeepsPlayerExpanded = containsPlayerPoint?(point) == true
                isHandlingPassiveLyrics = !lyricFocusKeepsPlayerExpanded
                isFocusingLyrics = true
                if lyricFocusKeepsPlayerExpanded { makeKey() }
                onKeyChanged?(lyricFocusKeepsPlayerExpanded)
            } else if containsPlayerPoint?(point) == true {
                focusPlayer()
            }
        }
        defer { isHandlingPassiveLyrics = false }
        super.sendEvent(event)
        if event.type == .leftMouseUp {
            updatePlayerPointer(at: CGPoint(x: event.locationInWindow.x, y: frame.height - event.locationInWindow.y))
        }
    }

    func updatePlayerPointer(at point: CGPoint?) {
        guard let point else {
            onPointerChanged?(false)
            return
        }
        onPointerChanged?(containsPlayerPoint?(point) ?? false)
    }

    func focusLyrics(keepingPlayerExpanded: Bool) {
        isFocusingLyrics = true
        lyricFocusKeepsPlayerExpanded = keepingPlayerExpanded
        onKeyChanged?(keepingPlayerExpanded)
        makeKeyAndOrderFront(nil)
        func reader(in view: NSView?) -> LyricReadingTextView? {
            guard let view else { return nil }
            if let text = view as? LyricReadingTextView { return text }
            return view.subviews.lazy.compactMap { reader(in: $0) }.first
        }
        if let text = reader(in: contentView) { makeFirstResponder(text) }
    }

    func focusPlayer() {
        endLyricsFocus()
        makeKey()
        onKeyChanged?(true)
    }

    func endLyricsFocus() {
        if isFocusingLyrics { makeFirstResponder(nil) }
        isFocusingLyrics = false
        lyricFocusKeepsPlayerExpanded = false
        onLyricsFocusEnded?()
    }

    func removeLyricsKeyboard() {
        endLyricsFocus()
        onLyricTab = nil
        onLyricActivate = nil
        onLyricsFocusEnded = nil
        onKeyChanged?(isKeyWindow)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.charactersIgnoringModifiers == "/",
           event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
           let onShowShortcuts {
            if !event.isARepeat { onShowShortcuts() }
            return true
        }
        if event.keyCode == kVK_ANSI_F,
           event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
           let onSearch {
            if !event.isARepeat { onSearch() }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if isFocusingLyrics {
            if event.keyCode == kVK_Tab { onLyricTab?(); return }
            if event.keyCode == kVK_Space || event.keyCode == kVK_Return,
               !(firstResponder is LyricReadingTextView) { onLyricActivate?(); return }
        }
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
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
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
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); (window as? StatusPanel)?.updatePlayerPointer(at: nil) }
    private func updatePointer(_ event: NSEvent) {
        guard let panel = window as? StatusPanel else { return }
        let point = CGPoint(x: event.locationInWindow.x, y: panel.frame.height - event.locationInWindow.y)
        panel.updatePlayerPointer(at: point)
    }
}
