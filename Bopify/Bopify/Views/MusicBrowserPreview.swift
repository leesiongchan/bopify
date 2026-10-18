#if DEBUG
import AppKit
import SwiftUI
import BopifyPlayback
import BopifyLibrary

/// Offline fixtures run inside the app so native materials and localization use the real bundle.
@MainActor
final class MusicBrowserPreviewSession {
    let environment = makePreviewEnvironment(.paused)
    private var window: NSWindow?
    private let defaults = UserDefaults(suiteName: "\(NSTemporaryDirectory())bopify-browser-preview")!

    func show() {
        defaults.set(ProcessInfo.processInfo.arguments.contains("--preview-library") ? "library" : "liked", forKey: "library.tab")
        let presentation = environment.presentation
        presentation.sendAttention(.visibility(true))
        presentation.sendAttention(.keyboardFocus(true))
        let controller = PlayerWindowController(previewMode: .expanded)
        let size = controller.layout.contentSize
        let view = RecordPlayerView(player: environment.player!, artworkStore: environment.artworkStore,
                                    presentation: presentation, windowController: controller)
            .environment(environment).defaultAppStorage(defaults)
            .frame(width: size.width, height: size.height)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Bopify — Library and Search Preview"
        window.isReleasedWhenClosed = false
        window.contentView = host
        self.window = window
        window.center()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        if ProcessInfo.processInfo.arguments.contains("--preview-search") {
            environment.search.updateQuery("Mira")
            environment.showSearch()
        }
    }
}
#endif
