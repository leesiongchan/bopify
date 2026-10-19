import AppKit
import SwiftUI

/// An agent app has no Settings menu, so Library Access gets its own window during setup and from the status menu.
@MainActor
final class LibrarySetupWindowController {
    private var window: NSWindow?

    func show(environment: AppEnvironment) {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: LibrarySetupView(environment: environment)))
            window.title = String(localized: "librarySetup.title")
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            self.window = window
        }
        window?.center()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }
}
