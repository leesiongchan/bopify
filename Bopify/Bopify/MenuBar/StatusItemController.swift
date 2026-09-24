import AppKit
import SwiftUI
import BopifyDomain
import BopifyPlayback
import os

@MainActor
final class StatusItemController {
    private let statusItem: NSStatusItem
    private var panel: StatusPanel?
    private var outsideClickMonitor: Any?
    private let environment: AppEnvironment

    init<Content: View>(content: Content, environment: AppEnvironment) {
        self.environment = environment
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Bopify")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(handleClick)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        panel = StatusPanel(content: content)
        panel?.onDismiss = { [weak self] in self?.dismiss() }
        panel?.onTogglePlayback = { [weak self] in
            guard let player = self?.environment.player, player.state.isActiveDevice,
                  player.state.phase == .playing || player.state.phase == .paused else { return }
            player.togglePlayPause()
        }
    }

    @objc private func handleClick() {
        // LSUIElement plus a non-activating panel means there is no app
        // menu and no route for Cmd-Q, so the conventional agent-app
        // pattern -- a secondary-click menu -- is the only way to sign out
        // or quit.
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            toggle()
        }
    }

    private func toggle() {
        guard let panel, let button = statusItem.button else { return }
        if panel.isVisible { dismiss(); return }

        if let frame = button.window?.convertToScreen(button.convert(button.bounds, to: nil)) {
            let visible = button.window?.screen?.visibleFrame ?? frame
            let origin = NSPoint(
                x: min(max(frame.midX - panel.frame.width / 2, visible.minX + 8), visible.maxX - panel.frame.width - 8),
                y: max(visible.minY + 8, frame.minY - panel.frame.height - 6)
            )
            panel.setFrameOrigin(origin)
        }
        panel.makeKeyAndOrderFront(nil)
        BopifyLog.playback.debug("player panel opened")

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }
    }

    private func dismiss() {
        panel?.orderOut(nil)
        if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor) }
        outsideClickMonitor = nil
        BopifyLog.playback.debug("player panel dismissed")
    }

    private func showMenu() {
        guard let button = statusItem.button else { return }
        let menu = NSMenu()

        let signOutItem = NSMenuItem(title: String(localized: "menu.signOut"),
                                      action: #selector(signOutTapped), keyEquivalent: "")
        signOutItem.target = self
        menu.addItem(signOutItem)

        let quitItem = NSMenuItem(title: String(localized: "menu.quit"),
                                   action: #selector(quitTapped), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
    }

    @objc private func signOutTapped() {
        Task { await environment.signOut() }
    }

    @objc private func quitTapped() {
        // `bopify_engine_destroy` (inside `shutdown()`) joins the Rust
        // runtime and then librespot's audio thread, with no timeout, so
        // this await can hang. Do the teardown here, not in
        // `applicationWillTerminate`, which is synchronous and cannot
        // await it.
        Task {
            await environment.prepareForQuit()
            NSApp.terminate(nil)
        }
    }
}
