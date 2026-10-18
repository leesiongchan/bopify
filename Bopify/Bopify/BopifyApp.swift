import SwiftUI
import BopifyDomain
import KeyboardShortcuts
import os

extension KeyboardShortcuts.Name {
    static let toggleLiveLyrics = Self("toggleLiveLyrics", initial: .init(.l, modifiers: [.control, .option]))
}

@main
struct BopifyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    var body: some Scene { Settings { EmptyView() } }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private var lyricShortcutTask: Task<Void, Never>?
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
            registerLyricShortcut { [weak preview] in
                guard let preview else { return }
                if preview.model.isVisible { preview.hide() }
                else { preview.show() }
            }
            return
        }
        #endif
        let environment = AppEnvironment()
        statusItemController = StatusItemController(content: PlayerRootView(environment: environment), environment: environment)
        registerLyricShortcut { [weak environment] in environment?.toggleLiveLyrics() }
        Task { await environment.restoreOrPromptSignIn() }
    }

    private func registerLyricShortcut(action: @escaping @MainActor () -> Void) {
        lyricShortcutTask?.cancel()
        let events = KeyboardShortcuts.events(for: .toggleLiveLyrics)
        if KeyboardShortcuts.isEnabled(for: .toggleLiveLyrics) {
            BopifyLog.playback.debug("Live lyrics global shortcut registered")
        } else {
            BopifyLog.playback.error("Live lyrics global shortcut unavailable; use the player lyrics control")
        }
        lyricShortcutTask = Task {
            for await event in events where event == .keyUp {
                guard !Task.isCancelled else { return }
                action()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        lyricShortcutTask?.cancel()
        lyricShortcutTask = nil
        #if DEBUG
        lyricPreview?.shutdown()
        #endif
    }
}
