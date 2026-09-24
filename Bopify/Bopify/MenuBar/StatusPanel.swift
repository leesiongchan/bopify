import AppKit
import SwiftUI

/// Borderless, non-activating panel anchored under the status item.
/// Non-activating keeps the app out of the foreground; canBecomeKey keeps
/// keyboard events working inside it.
final class StatusPanel: NSPanel {
    var onDismiss: (() -> Void)?
    var onTogglePlayback: (() -> Void)?

    init<Content: View>(content: Content) {
        super.init(contentRect: NSRect(x: 0, y: 0,
                                      width: PlayerSurface<EmptyView>.width,
                                      height: PlayerSurface<EmptyView>.height),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovable = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        contentView = NSHostingView(rootView: content)
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onDismiss?()
    }

    override func keyDown(with event: NSEvent) {
        // Let text editors and focused controls handle Space before it reaches the panel.
        if event.keyCode == 49, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
            if !event.isARepeat { onTogglePlayback?() }
        } else {
            super.keyDown(with: event)
        }
    }
}
