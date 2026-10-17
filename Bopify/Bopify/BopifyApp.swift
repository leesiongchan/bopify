import SwiftUI

@main
struct BopifyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    var body: some Scene { Settings { EmptyView() } }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    #if DEBUG
    private var lyricPreview: LyricRibbonPreviewSession?
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--lyric-ribbon-preview") {
            let preview = LyricRibbonPreviewSession()
            lyricPreview = preview
            preview.showControls()
            preview.show()
            return
        }
        #endif
        let environment = AppEnvironment()
        statusItemController = StatusItemController(content: PlayerRootView(environment: environment), environment: environment)
        Task { await environment.restoreOrPromptSignIn() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        #if DEBUG
        lyricPreview?.shutdown()
        #endif
    }
}
