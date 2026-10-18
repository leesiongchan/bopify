import AppKit
import SwiftUI

/// An agent app has no Settings menu, so Library Access gets its own window, opened from the status menu or any Enable action.
@MainActor
final class LibrarySetupWindowController: NSObject, NSWindowDelegate {
    var isVisible: Bool { window?.isVisible == true }
    private var window: NSWindow?
    private var onCancel: (() -> Void)?

    func show(environment: AppEnvironment) {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: LibrarySetupView(environment: environment)))
            window.title = String(localized: "librarySetup.title")
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            self.window = window
        }
        onCancel = { [weak environment] in environment?.searchPopover.close() }
        window?.center()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func close() { onCancel = nil; window?.close() }

    func windowWillClose(_ notification: Notification) {
        onCancel?()
        onCancel = nil
    }
}
