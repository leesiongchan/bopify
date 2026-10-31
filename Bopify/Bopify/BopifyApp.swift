import SwiftUI
import BopifyDomain
import KeyboardShortcuts
import os

@main
struct BopifyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    var body: some Scene { Settings { EmptyView() } }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private var shortcutTasks: [Task<Void, Never>] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let environment = AppEnvironment()
        let controller = StatusItemController(content: PlayerRootView(environment: environment), environment: environment)
        statusItemController = controller
        controller.showPlayer()
        registerShortcut(.togglePlayer) { [weak controller] in controller?.togglePlayer() }
        registerShortcut(.searchMusic) { [weak controller] in controller?.showSearch() }
        registerShortcut(.toggleLiveLyrics) { [weak environment] in environment?.toggleLiveLyrics() }
        Task { await environment.restoreOrPromptSignIn() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItemController?.showPlayer()
        return false
    }

    private func registerShortcut(_ name: KeyboardShortcuts.Name, action: @escaping @MainActor () -> Void) {
        let events = KeyboardShortcuts.events(for: name)
        if name.shortcut != nil && !KeyboardShortcuts.isEnabled(for: name) {
            BopifyLog.playback.error("Global shortcut unavailable action=\(name.rawValue, privacy: .public); use the player controls")
        }
        shortcutTasks.append(Task {
            for await event in events where event == .keyUp {
                guard !Task.isCancelled else { return }
                action()
            }
        })
    }

    func applicationWillTerminate(_ notification: Notification) {
        shortcutTasks.forEach { $0.cancel() }
        shortcutTasks.removeAll()
    }
}
