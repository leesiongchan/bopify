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
    #if DEBUG
    private var lyricPreview: LyricPanelPreviewSession?
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--lyrics-preview") {
            let preview = LyricPanelPreviewSession()
            lyricPreview = preview
            preview.showControls()
            preview.show()
            registerShortcut(.toggleLiveLyrics) { [weak preview] in
                guard let preview else { return }
                if preview.model.isVisible { preview.hide() }
                else { preview.show() }
            }
            return
        }
        #endif
        let environment = AppEnvironment()
        let controller = StatusItemController(content: PlayerRootView(environment: environment), environment: environment)
        statusItemController = controller
        registerShortcut(.togglePlayer) { [weak controller] in controller?.togglePlayer() }
        registerShortcut(.searchMusic) { [weak controller] in controller?.showSearch() }
        registerShortcut(.toggleLiveLyrics) { [weak environment] in environment?.toggleLiveLyrics() }
        Task { await environment.restoreOrPromptSignIn() }
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
        #if DEBUG
        lyricPreview?.shutdown()
        #endif
    }
}
