import SwiftUI

@main
struct BopifyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    var body: some Scene { Settings { EmptyView() } }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var environment = AppEnvironment()
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItemController = StatusItemController(content: PlayerRootView(environment: environment), environment: environment)
        Task { await environment.restoreOrPromptSignIn() }
    }
}
