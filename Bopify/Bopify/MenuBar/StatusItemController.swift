import AppKit
import SwiftUI
import Observation
import BopifyDomain
import BopifyPlayback
import os

@MainActor
final class StatusItemController: NSObject, NSWindowDelegate {
    private let statusItem: NSStatusItem
    private var panel: StatusPanel?
    private var hasPosition = false
    private var appliedMode: PlayerMode?
    private var isApplyingFrame = false
    private var isWindowControllerAttached = false
    private let environment: AppEnvironment

    init<Content: View>(content: Content, environment: AppEnvironment) {
        self.environment = environment
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        statusItem.button?.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Bopify")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        panel = StatusPanel(content: content)
        panel?.delegate = self
        panel?.onDismiss = { [weak self] in self?.dismiss() }
        panel?.onTogglePlayback = { [weak self] in
            // Space acts as the Play button, including play-here while inactive.
            guard let player = self?.environment.player else { return }
            if player.state.isActiveDevice {
                guard player.state.phase == .playing || player.state.phase == .paused else { return }
            } else {
                guard player.canPlayHere, player.state.phase != .loading, player.state.phase != .buffering else { return }
            }
            player.togglePlayPause()
        }
        panel?.onSeek = { [weak self] in self?.environment.player?.seek(by: $0) }
        panel?.onPrevious = { [weak self] in self?.environment.player?.previous() }
        panel?.onNext = { [weak self] in self?.environment.player?.next() }
        panel?.onDismissPopover = { [weak self] in self?.environment.presentation.dismissPopover() ?? false }
        panel?.onDismissQueue = { [weak self] in self?.environment.presentation.dismissQueue() ?? false }
        panel?.onKeyChanged = { [weak self] in self?.environment.presentation.sendAttention(.keyboardFocus($0)) }
        panel?.onPointerChanged = { [weak self] in self?.environment.presentation.sendAttention(.pointer($0)) }
        panel?.onWindowDragChanged = { [weak self] active in
            guard let self else { return }
            self.environment.playerWindowController.setDragging(active)
            self.environment.presentation.sendAttention(.interaction(.windowDrag, active))
        }
        if let stored = UserDefaults.standard.string(forKey: "player.frame") {
            let frame = NSRectFromString(stored)
            if frame.width > 0, frame.height > 0 {
                panel?.setFrame(frame, display: false)
                hasPosition = true
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersDidChange(_:)),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        observePresentation()
    }

    private func observePresentation() {
        withObservationTracking {
            configure(mode: environment.playerMode, keepOnTop: environment.presentation.keepOnTop)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observePresentation() }
        }
    }

    private func configure(mode: PlayerMode, keepOnTop: Bool) {
        guard let panel else { return }
        panel.level = keepOnTop ? .floating : .normal
        UserDefaults.standard.set(keepOnTop, forKey: "player.keepOnTop")
        if environment.isListening {
            if !isWindowControllerAttached {
                if !hasPosition, PlayerWindowController.restoredAnchor(defaults: .standard) == nil,
                   let button = statusItem.button,
                   let frame = button.window?.convertToScreen(button.convert(button.bounds, to: nil)) {
                    panel.setFrame(CGRect(x: frame.midX - 71, y: frame.minY - 148, width: 142, height: 142), display: false)
                }
                environment.playerWindowController.attach(to: panel)
                environment.presentation.sendAttention(.visibility(panel.isVisible))
                if panel.isKeyWindow { environment.presentation.sendAttention(.keyboardFocus(true)) }
                isWindowControllerAttached = true
                // The new composition has no rendered player geometry to animate from yet.
                environment.playerWindowController.apply(mode: environment.presentation.mode, reduceMotion: true)
                BopifyLog.playback.debug("Player listening geometry initialized")
            }
            environment.playerWindowController.apply(mode: environment.presentation.mode,
                                              reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            return
        }
        if isWindowControllerAttached {
            environment.playerWindowController.invalidateTransition()
            panel.containsPlayerPoint = nil
            environment.presentation.resetEngagement()
            environment.presentation.sendAttention(.visibility(panel.isVisible))
            panel.styleMask.insert(.resizable)
            panel.hasShadow = true
            isWindowControllerAttached = false
            appliedMode = nil
        }
        guard appliedMode != mode else { return }
        let compact = mode == .compact
        let oldFrame = panel.frame
        let crossingCompact = (appliedMode == .compact) != compact
        let size = appliedMode == nil || !crossingCompact ? oldFrame.size : NSSize(width: compact ? 380 : 410, height: compact ? 88 : 560)
        appliedMode = mode
        setReachableFrame(origin: NSPoint(x: oldFrame.minX, y: oldFrame.maxY - size.height), size: size,
                          animate: panel.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        BopifyLog.playback.debug("player presentation changed mode=\(mode.rawValue, privacy: .public)")
    }

    private func setReachableFrame(origin: NSPoint, size: NSSize, animate: Bool = false) {
        guard let panel else { return }
        let proposed = NSRect(origin: origin, size: size)
        let screen = NSScreen.screens.max { first, second in
            let a = first.visibleFrame.intersection(proposed)
            let b = second.visibleFrame.intersection(proposed)
            return (a.isNull ? 0 : a.width * a.height) < (b.isNull ? 0 : b.width * b.height)
        } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let compact = appliedMode == .compact
        let minimum = NSSize(width: compact ? 340 : 390, height: compact ? 88 : 560)
        let maximum = NSSize(width: compact ? 420 : 430, height: compact ? 88 : 800)
        let requested = NSSize(width: min(maximum.width, max(minimum.width, size.width)),
                               height: min(maximum.height, max(minimum.height, size.height)))
        isApplyingFrame = true
        panel.minSize = NSSize(width: min(minimum.width, visible.width), height: min(minimum.height, visible.height))
        panel.maxSize = NSSize(width: min(maximum.width, visible.width), height: min(maximum.height, visible.height))
        panel.setFrame(clampedPlayerFrame(origin: origin, size: requested, visibleFrame: visible), display: true, animate: animate)
        isApplyingFrame = false
        if hasPosition { saveFrame() }
    }

    @objc private func screenParametersDidChange(_ notification: Notification) { reposition() }

    private func reposition() {
        guard let panel else { return }
        if isWindowControllerAttached {
            environment.playerWindowController.apply(mode: environment.presentation.mode, reduceMotion: true)
            return
        }
        setReachableFrame(origin: panel.frame.origin, size: panel.frame.size)
    }

    private func saveFrame() {
        guard let panel, hasPosition, !isApplyingFrame else { return }
        if isWindowControllerAttached { return }
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: "player.frame")
    }
    func windowDidBecomeKey(_ notification: Notification) { Task { await environment.refreshFavorite() } }
    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidResize(_ notification: Notification) { saveFrame() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { dismiss(); return false }


    @objc private func statusItemClicked(_ sender: Any?) {
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

        if isWindowControllerAttached {
            hasPosition = true
            reposition()
        } else if !hasPosition, let frame = button.window?.convertToScreen(button.convert(button.bounds, to: nil)) {
            hasPosition = true
            setReachableFrame(origin: NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY - panel.frame.height - 6), size: panel.frame.size)
        } else {
            reposition()
        }
        environment.presentation.isVisible = true
        environment.presentation.sendAttention(.keyboardFocus(true))
        if isWindowControllerAttached { environment.playerWindowController.apply(mode: .expanded, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) }
        panel.makeKeyAndOrderFront(nil)
        BopifyLog.playback.debug("player panel opened")
    }

    private func dismiss() {
        saveFrame()
        if isWindowControllerAttached { environment.playerWindowController.persistAnchor(); environment.playerWindowController.invalidateTransition() }
        environment.presentation.isVisible = false
        panel?.orderOut(nil)
        BopifyLog.playback.debug("player panel hidden")
    }

    private func showMenu() {
        guard let button = statusItem.button else { return }
        let menu = NSMenu()
        environment.presentation.sendAttention(.interaction(.menu, true))
        defer { environment.presentation.sendAttention(.interaction(.menu, false)) }
        let keepOnTop = NSMenuItem(title: String(localized: "window.keepOnTop"), action: #selector(toggleKeepOnTop(_:)), keyEquivalent: "")
        keepOnTop.target = self
        keepOnTop.state = environment.presentation.keepOnTop ? .on : .off
        menu.addItem(keepOnTop)
        let libraryItem = NSMenuItem(title: String(localized: "menu.libraryAccess"),
                                     action: #selector(showLibraryAccess(_:)), keyEquivalent: "")
        libraryItem.target = self
        menu.addItem(libraryItem)
        if environment.isAuthorizingPlayback {
            let cancel = NSMenuItem(title: String(localized: "signIn.cancel"), action: #selector(cancelPlaybackAuthorization(_:)), keyEquivalent: "")
            cancel.target = self
            menu.addItem(cancel)
        }
        if environment.isEnablingLibrary {
            let cancel = NSMenuItem(title: String(localized: "library.cancelAuthorization"), action: #selector(cancelLibraryAuthorization(_:)), keyEquivalent: "")
            cancel.target = self
            menu.addItem(cancel)
        }
        menu.addItem(.separator())

        let signOutItem = NSMenuItem(title: String(localized: "menu.signOut"),
                                      action: #selector(signOut(_:)), keyEquivalent: "")
        signOutItem.target = self
        menu.addItem(signOutItem)

        let quitItem = NSMenuItem(title: String(localized: "menu.quit"),
                                   action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
    }

    @objc private func signOut(_ sender: Any?) {
        Task { await environment.signOut() }
    }
    @objc private func cancelPlaybackAuthorization(_ sender: Any?) { environment.cancelPlaybackAuthorization() }
    @objc private func cancelLibraryAuthorization(_ sender: Any?) { environment.cancelLibraryAuthorization() }
    @objc private func showLibraryAccess(_ sender: Any?) { environment.librarySetupWindow.show(environment: environment) }
    @objc private func toggleKeepOnTop(_ sender: Any?) { environment.presentation.keepOnTop.toggle() }

    @objc private func quit(_ sender: Any?) {
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
