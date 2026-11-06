import AppKit
import SwiftUI

@MainActor final class SoloistSetupWindowController {
    private var window: NSWindow?
    func show(environment: AppEnvironment) {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SoloistSetupView(environment: environment)))
            window.title = SoloistResources.string("soloist.title")
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
            window.backgroundColor = .clear; window.isOpaque = false
            window.isMovableByWindowBackground = true; window.isReleasedWhenClosed = false
            window.level = .floating
            self.window = window
        }
        if window?.isVisible != true { window?.center() }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
    func close() { window?.close() }
}
