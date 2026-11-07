import SwiftUI
import Darwin
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
        if CommandLine.arguments.contains(SoloistInstallationCheck.argument) {
            Task { exit(await SoloistInstallationCheck.run()) }
            return
        }
        finishDesktopMigrationAndStart()
    }

    private func finishDesktopMigrationAndStart() {
        do { try DesktopDataMigration().run() }
        catch {
            BopifyLog.auth.error("desktop data migration blocked; authentication deferred")
            let alert = NSAlert()
            alert.messageText = SoloistResources.string("desktopMigration.title")
            alert.informativeText = SoloistResources.string("desktopMigration.message")
            alert.addButton(withTitle: SoloistResources.string("desktopMigration.retry"))
            alert.addButton(withTitle: SoloistResources.string("desktopMigration.quit"))
            NSApp.activate()
            if alert.runModal() == .alertFirstButtonReturn {
                Task { @MainActor in self.finishDesktopMigrationAndStart() }
            } else { NSApp.terminate(nil) }
            return
        }
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
