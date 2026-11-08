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
    private var holdsOnboardingAttention = false
    private var awaitsInitialPlayerInteraction = false
    private var isPointerInside = false
    private var startupHeight: CGFloat?
    private var preparedStartupContent: StartupWindowLayout.MeasurementKey?
    private let environment: AppEnvironment
    private let shortcutsWindow = KeyboardShortcutsWindowController()
    private let recordAppearanceWindow = RecordAppearanceWindowController()

    init<Content: View>(content: Content, environment: AppEnvironment) {
        self.environment = environment
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        let mark = NSImage(resource: .bopStatus).withSymbolConfiguration(.init(pointSize: 16, weight: .regular))
        mark?.isTemplate = true
        mark?.accessibilityDescription = "Bopify"
        statusItem.button?.image = mark
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        panel = StatusPanel(content: content)
        if let panel { environment.playerWindowController.attach(to: panel) }
        panel?.delegate = self
        panel?.onDismiss = { [weak self] in self?.dismiss() }
        panel?.onTogglePlayback = { [weak self] in
            // Space acts as the Play button, including play-here while inactive.
            guard let player = self?.environment.player else { return }
            if player.state.isActiveDevice {
                guard player.state.phase == .playing || player.state.phase == .paused else { return }
            } else {
                guard player.canPlayHere, player.state.phase != .loading else { return }
            }
            player.togglePlayPause()
        }
        panel?.onSeek = { [weak self] in self?.environment.player?.seek(by: $0) }
        panel?.onPrevious = { [weak self] in self?.environment.player?.previous() }
        panel?.onNext = { [weak self] in self?.environment.player?.next() }
        panel?.onSearch = { [weak self] in self?.showSearch() }
        panel?.onShowShortcuts = { [weak self] in self?.shortcutsWindow.show() }
        panel?.onDismissPopover = { [weak self] in self?.environment.presentation.dismissPopover() ?? false }
        panel?.onDismissQueue = { [weak self] in self?.environment.presentation.dismissQueue() ?? false }
        panel?.onKeyChanged = { [weak self] focused in
            guard let self else { return }
            if focused { self.awaitsInitialPlayerInteraction = false }
            self.environment.presentation.sendAttention(.keyboardFocus(focused))
        }
        panel?.onPointerChanged = { [weak self] inside in
            guard let self else { return }
            self.isPointerInside = inside
            if inside { self.awaitsInitialPlayerInteraction = false }
            self.environment.presentation.sendAttention(.pointer(inside))
        }
        panel?.onWindowDragChanged = { [weak self] active in
            guard let self else { return }
            if self.isWindowControllerAttached { self.environment.playerWindowController.setDragging(active) }
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

    private func updateOnboardingAttention() {
        if !environment.presentation.isVisible || (!environment.isShowingPlayer && !environment.onboarding.isArmed) {
            awaitsInitialPlayerInteraction = false
        }
        let holds = (environment.onboarding.isArmed || awaitsInitialPlayerInteraction) && environment.presentation.isVisible
        guard holds != holdsOnboardingAttention else { return }
        holdsOnboardingAttention = holds
        environment.presentation.sendAttention(.interaction(.onboarding, holds))
    }

    private func configure(mode: PlayerMode, keepOnTop: Bool, preparingDisplay: Bool = false) {
        guard !environment.isPreparingForQuit, let panel else { return }
        updateOnboardingAttention()
        let floatingLyrics = environment.isLiveLyricsVisible && environment.presentation.mode == .compact
        let onboarding = environment.isShowingOnboarding
            || environment.authState != .signedIn
            || (!environment.hasPlaybackConnected && environment.connectionStatus != .ready)
        let level: NSWindow.Level = keepOnTop || floatingLyrics || onboarding ? .floating : .normal
        if panel.level != level {
            panel.level = level
            if environment.onboarding.phase == .handoff, panel.isVisible {
                // Lowering the setup window's level otherwise places it behind the authorization browser.
                panel.orderFrontRegardless()
                BopifyLog.playback.info("onboarding player brought forward focused=\(panel.isKeyWindow, privacy: .public)")
            }
            BopifyLog.playback.debug("player window level changed floating=\(level == .floating, privacy: .public)")
        }
        UserDefaults.standard.set(keepOnTop, forKey: "player.keepOnTop")
        if environment.isShowingPlayer {
            preparedStartupContent = nil
            environment.startupWindow.cancelPendingResize()
            startupHeight = nil
            if !isWindowControllerAttached {
                let handingOff = environment.onboarding.phase == .handoff
                if handingOff {
                    awaitsInitialPlayerInteraction = panel.isVisible && !panel.isKeyWindow && !isPointerInside
                }
                if !handingOff, !hasPosition, PlayerWindowController.restoredAnchor(defaults: .standard) == nil,
                   let button = statusItem.button,
                   let frame = button.window?.convertToScreen(button.convert(button.bounds, to: nil)) {
                    panel.setFrame(CGRect(x: frame.midX - 71, y: frame.minY - 148, width: 142, height: 142), display: false)
                }
                environment.playerWindowController.attach(to: panel,
                    onboardingRecordFrame: handingOff ? environment.onboardingRecordFrame : nil,
                    onboardingID: handingOff ? environment.onboarding.completionID : nil,
                    onOnboardingSettled: { [weak self] id in
                        guard let self, self.environment.onboarding.completionID == id,
                              self.environment.onboarding.phase == .handoff else { return }
                        self.environment.onboarding.handoffSettled(for: id)
                    })
                environment.presentation.sendAttention(.visibility(panel.isVisible))
                if panel.isKeyWindow { environment.presentation.sendAttention(.keyboardFocus(true)) }
                isWindowControllerAttached = true
                // Initial restoration has no prior player geometry; onboarding has a visible record to preserve.
                environment.playerWindowController.apply(mode: environment.presentation.mode,
                                                         animated: handingOff,
                                                         showsLyrics: environment.isLiveLyricsVisible)
                BopifyLog.playback.debug("Player listening geometry initialized")
            }
            environment.playerWindowController.apply(mode: environment.presentation.mode,
                                                     showsLyrics: environment.isLiveLyricsVisible)
            return
        }
        if isWindowControllerAttached {
            environment.playerWindowController.invalidateTransition()
            holdsOnboardingAttention = false
            environment.presentation.resetEngagement()
            environment.presentation.sendAttention(.visibility(panel.isVisible))
            updateOnboardingAttention()
            isWindowControllerAttached = false
            appliedMode = nil
        }
        panel.containsPlayerPoint = nil
        panel.containsLyricsPoint = nil
        panel.styleMask.insert(.resizable)
        // Like the record's halo, the startup glass would get a hard rectangular outline from the native shadow.
        panel.hasShadow = false
        if onboarding {
            let oldFrame = panel.frame
            let visible = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            if let visible { environment.startupWindow.useScreen(height: visible.height) }
            let requestedWidth = appliedMode == nil ? max(410, oldFrame.width) : oldFrame.width
            let width = min(visible?.width ?? 430, min(430, max(390, requestedWidth)))
            if let step = environment.onboardingStep {
                let root = PlayerRootView(environment: environment)
                let key = root.startupMeasurementKey(for: step, width: width)
                if preparingDisplay || preparedStartupContent != key {
                    root.prepareStartupSizing(for: step, width: width, immediately: !panel.isVisible)
                    preparedStartupContent = key
                }
            }
            let height = environment.startupWindow.height
            startupHeight = height
            guard appliedMode != mode || abs(oldFrame.width - width) >= 0.5 || abs(oldFrame.height - height) >= 0.5 else { return }
            appliedMode = mode
            setReachableFrame(origin: NSPoint(x: oldFrame.minX, y: oldFrame.maxY - height),
                              size: NSSize(width: width, height: height),
                              animate: panel.isVisible)
            BopifyLog.playback.debug("startup window resized height=\(Int(panel.frame.height), privacy: .public)")
            return
        }
        startupHeight = nil
        guard appliedMode != mode else { return }
        let compact = mode == .compact
        let oldFrame = panel.frame
        let crossingCompact = (appliedMode == .compact) != compact
        let size = appliedMode == nil || !crossingCompact ? oldFrame.size : NSSize(width: compact ? 380 : 410, height: compact ? 88 : 560)
        appliedMode = mode
        setReachableFrame(origin: NSPoint(x: oldFrame.minX, y: oldFrame.maxY - size.height), size: size,
                          animate: panel.isVisible)
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
        let minimum = NSSize(width: compact ? 340 : 390, height: compact ? 88 : (startupHeight ?? 680))
        let maximum = NSSize(width: compact ? 420 : 430, height: compact ? 88 : (startupHeight == nil ? 800 : visible.height))
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
        guard !environment.isPreparingForQuit, let panel else { return }
        if isWindowControllerAttached {
            environment.playerWindowController.apply(mode: environment.presentation.mode, animated: false,
                                                     showsLyrics: environment.isLiveLyricsVisible)
            return
        }
        if startupHeight != nil {
            if let visible = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
                environment.startupWindow.useScreen(height: visible.height)
            }
            let height = environment.startupWindow.height
            startupHeight = height
            setReachableFrame(origin: NSPoint(x: panel.frame.minX, y: panel.frame.maxY - height),
                              size: NSSize(width: panel.frame.width, height: height))
        } else {
            setReachableFrame(origin: panel.frame.origin, size: panel.frame.size)
        }
    }

    private func saveFrame() {
        guard let panel, hasPosition, !isApplyingFrame else { return }
        if isWindowControllerAttached { return }
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: "player.frame")
    }
    func windowDidBecomeKey(_ notification: Notification) { Task { await environment.refreshFavorite() } }
    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidResize(_ notification: Notification) { saveFrame() }
    func windowDidChangeScreen(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self, !self.isWindowControllerAttached else { return }
            self.reposition()
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { dismiss(); return false }


    @objc private func statusItemClicked(_ sender: Any?) {
        // LSUIElement plus a non-activating panel means there is no app
        // menu and no route for Cmd-Q, so the conventional agent-app
        // pattern -- a secondary-click menu -- is the only way to sign out
        // or quit.
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            togglePlayer()
        }
    }

    func togglePlayer() {
        guard !environment.isPreparingForQuit, let panel else { return }
        if panel.isVisible && (panel.isKeyWindow || environment.searchPopover.isVisible) { dismiss(); return }
        showPlayer()
    }

    func showSearch() {
        guard !environment.isPreparingForQuit else { return }
        showPlayer()
        environment.showSearch()
    }

    func showPlayer() {
        guard !environment.isPreparingForQuit, let panel, let button = statusItem.button else { return }

        if !panel.isVisible {
            configure(mode: environment.playerMode, keepOnTop: environment.presentation.keepOnTop, preparingDisplay: true)
        }

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
        if isWindowControllerAttached { environment.playerWindowController.apply(mode: .expanded,
                                                                               showsLyrics: environment.isLiveLyricsVisible) }
        panel.makeKeyAndOrderFront(nil)
        panel.focusPlayer()
        panel.orderFrontRegardless()
        BopifyLog.playback.debug("player panel opened")
    }

    private func dismiss() {
        if environment.searchPopover.isVisible { environment.searchPopover.close() }
        saveFrame()
        if isWindowControllerAttached { environment.playerWindowController.hide() }
        awaitsInitialPlayerInteraction = false
        holdsOnboardingAttention = false
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
        let artworkBackground = NSMenuItem(title: String(localized: "menu.artworkBackground"),
                                          action: #selector(toggleArtworkBackground(_:)), keyEquivalent: "")
        artworkBackground.target = self
        artworkBackground.state = (UserDefaults.standard.object(forKey: "player.artworkBackground") as? Bool ?? true) ? .on : .off
        menu.addItem(artworkBackground)
        let appearance = NSMenuItem(title: String(localized: "menu.recordAppearance"),
                                    action: #selector(showRecordAppearance(_:)), keyEquivalent: "")
        appearance.target = self
        menu.addItem(appearance)
        let shortcutsItem = NSMenuItem(title: String(localized: "shortcuts.title"),
                                      action: #selector(showShortcuts(_:)), keyEquivalent: "/")
        shortcutsItem.target = self
        menu.addItem(shortcutsItem)
        if environment.isAuthorizingPlayback {
            let cancel = NSMenuItem(title: String(localized: "signIn.cancel"), action: #selector(cancelPlaybackAuthorization(_:)), keyEquivalent: "")
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

        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: "Bopify \(version)", action: nil, keyEquivalent: ""))
        }

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
    }

    @objc private func signOut(_ sender: Any?) {
        Task { await environment.signOut() }
    }
    @objc private func cancelPlaybackAuthorization(_ sender: Any?) { environment.cancelPlaybackAuthorization() }
    @objc private func showShortcuts(_ sender: Any?) { shortcutsWindow.show() }
    @objc private func showRecordAppearance(_ sender: Any?) { recordAppearanceWindow.show() }
    @objc private func toggleKeepOnTop(_ sender: Any?) { environment.presentation.keepOnTop.toggle() }
    @objc private func toggleArtworkBackground(_ sender: Any?) {
        let enabled = !(UserDefaults.standard.object(forKey: "player.artworkBackground") as? Bool ?? true)
        UserDefaults.standard.set(enabled, forKey: "player.artworkBackground")
        BopifyLog.playback.debug("artwork background changed enabled=\(enabled, privacy: .public)")
    }

    @objc private func quit(_ sender: Any?) {
        // Shutdown joins the owned Soloist process and companion data tasks.
        // applicationWillTerminate is synchronous and cannot await that teardown.
        Task {
            await environment.prepareForQuit()
            NSApp.terminate(nil)
        }
    }
}
