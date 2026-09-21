import AppKit
import SwiftUI

/// Borderless, non-activating panel anchored under the status item.
/// Non-activating keeps the app out of the foreground; canBecomeKey keeps
/// keyboard events working inside it.
final class StatusPanel: NSPanel {
    init<Content: View>(content: Content) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovable = false
        backgroundColor = .clear
        contentView = NSHostingView(rootView: content)
    }

    override var canBecomeKey: Bool { true }
}
