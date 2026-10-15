import AppKit
import SwiftUI
import Observation
import BopifyDomain
import BopifyPlayback

@MainActor @Observable private final class InteractionState: NSObject {
    var status: PlaybackConnectionStatus = .offline
    var unavailable = false
    var retries = 0
    var reconnects = 0
    let presentation = PlayerPresentation()
    let output: URL
    let integrated: Bool
    var menuOpen = false
    var lastCommand = ""
    var timer: Timer?
    weak var trackingMenu: NSMenu?
    var snapshotNumber = 0
    var trackingEvents: [String] = []
    var pendingTitles: [String] = []
    var trackingTimedOut = false
    var trackingMismatch = false
    init(output: URL, integrated: Bool) { self.output = output; self.integrated = integrated; super.init() }
    var connection: PlaybackConnectionStatusView {
        PlaybackConnectionStatusView(status: status, restorationUnavailable: unavailable,
            onRetry: { self.retries += 1; self.snapshot() },
            onReconnect: { self.reconnects += 1; self.snapshot() })
    }
    func snapshot() {
        snapshotNumber += 1
        let state: [String: Any] = ["retries": retries, "reconnects": reconnects,
            "mode": presentation.mode.rawValue, "menuOpen": menuOpen, "command": lastCommand,
            "keyboardNavigationEnabled": NSApp.isFullKeyboardAccessEnabled,
            "snapshotNumber": snapshotNumber, "menuTitles": trackingMenu?.items.map(\.title) ?? []]
        try! JSONSerialization.data(withJSONObject: state).write(to: output.appendingPathComponent("state.json"), options: .atomic)
    }
    func command(_ value: String) {
        switch value {
        case "offline": status = .offline; unavailable = false
        case "reconnecting": status = .reconnecting; unavailable = false
        case "restoration": status = .ready; unavailable = true
        case "reauthentication": status = .needsReauthentication; unavailable = false
        case "corrupt": status = .failed(.credentialCorrupt); unavailable = false
        case "credentials": status = .failed(.credentialSaveFailed); unavailable = false
        case "permanent": status = .failed(.premiumRequired); unavailable = false
        case "long": status = .failed(.credentialCleanupNotRecorded); unavailable = false
        case "ready": status = .ready; unavailable = false
        case "collapse": presentation.resetEngagement(); presentation.sendAttention(.visibility(true))
        default: break
        }
        lastCommand = value
        snapshot()
    }
    func start() {
        presentation.sendAttention(.visibility(true))
        timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let data = try? String(contentsOf: self.output.appendingPathComponent("command.txt"), encoding: .utf8), data != self.lastCommand {
                    self.command(data)
                }
                self.snapshot()
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
        NotificationCenter.default.addObserver(self, selector: #selector(menuBegan(_:)), name: NSMenu.didBeginTrackingNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(menuEnded(_:)), name: NSMenu.didEndTrackingNotification, object: nil)

    }
    func checkPendingRetry(in panel: StatusPanel, changedAction: Bool) async -> Int32 {
        func attribute(_ object: NSObject, _ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() : nil
        }
        func tree(_ object: Any) -> [NSObject] {
            guard let object = object as? NSObject else { return [] }
            return [object] + ((attribute(object, "accessibilityChildren") as? [Any]) ?? []).flatMap(tree)
        }
        let press: @MainActor @Sendable (NSObject, String) -> Bool = { object, name in
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector) else { return false }
            typealias Action = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(object.method(for: selector), to: Action.self)(object, selector)
        }
        let appearanceDeadline = ContinuousClock.now + .seconds(2)
        var button: NSObject?
        while button == nil && ContinuousClock.now < appearanceDeadline {
            button = tree(panel.contentView!).first { attribute($0, "accessibilityRole") as? String == "AXMenuButton" }
            if button == nil { try? await Task.sleep(for: .milliseconds(10)) }
        }
        guard let button else { return 77 }
        let target = changedAction ? "reauthentication" : "reconnecting"
        let mutation = Timer(timeInterval: 0.3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.menuOpen else { return }
                self.trackingEvents.append("change")
                self.command(target)
            }
        }
        let selection = Timer(timeInterval: 0.8, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.menuOpen else { return }
                self.pendingTitles = self.trackingMenu?.items.map(\.title) ?? []
                guard let item = self.trackingMenu?.items.first(where: { $0.title == "Retry now" }), !self.pendingTitles.contains("Reconnect Spotify") else {
                    self.trackingMismatch = true
                    return
                }
                // AppKit may return false despite dispatching; verify counters and actual tracking end instead.
                _ = press(item, "accessibilityPerformPress")
            }
        }
        let watchdog = Timer(timeInterval: 1.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackingTimedOut = true; self?.trackingMenu?.cancelTracking() }
        }
        for timer in [mutation, selection, watchdog] { RunLoop.main.add(timer, forMode: .common) }
        _ = press(button, "accessibilityPerformShowMenu") || press(button, "accessibilityPerformPress")
        let deadline = ContinuousClock.now + .seconds(2)
        while trackingEvents.isEmpty && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        while menuOpen && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        for timer in [mutation, selection, watchdog] { timer.invalidate() }
        let validLifecycle = trackingEvents == ["began", "change", "ended"]
        let passed = validLifecycle && !trackingMismatch && !trackingTimedOut && reconnects == 0 &&
            (retries == 1 || changedAction && retries == 0 && pendingTitles.isEmpty)
        let code: Int32 = !trackingEvents.contains("change") ? 77 : passed ? 0 : 2
        let result: [String: Any] = ["exit_code": code, "events": trackingEvents, "pendingTitles": pendingTitles,
            "retries": retries, "reconnects": reconnects, "watchdogCancelled": trackingTimedOut, "changedAction": changedAction]
        let data = try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try! data.write(to: output.appendingPathComponent("pending-retry-result.json"), options: .atomic)
        print(String(data: data, encoding: .utf8)!); fflush(stdout)
        return code
    }

    @objc func menuBegan(_ notification: Notification) {
        menuOpen = true
        trackingEvents.append("began")
        trackingMenu = notification.object as? NSMenu
        snapshot()
    }
    @objc func menuEnded(_ notification: Notification) {
        menuOpen = false
        trackingEvents.append("ended")
        trackingMenu = nil
        snapshot()
    }
}

private struct InteractionView: View {
    let state: InteractionState
    var body: some View {
        VStack {
            if state.integrated && state.presentation.mode != .compact {
                state.connection
                    .frame(width: 320, height: 80)
            } else {
                ZStack(alignment: .bottom) {
                    Circle().fill(.gray.opacity(0.2)).frame(width: 118, height: 118)
                    if state.connection.isVisible {
                        CompactPlaybackConnectionMenu(connection: state.connection)
                            .frame(width: 94, height: 24)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.bottom, 12)
                    }
                }.frame(width: 142, height: 142)
            }
        }.frame(width: 340, height: 180)
    }
}

@main @MainActor private struct RecoveryMenuInteractionApp {
    static func main() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--output"), index + 1 < arguments.count else { exit(2) }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let state = InteractionState(output: URL(fileURLWithPath: arguments[index + 1]), integrated: arguments.contains("--integrated"))
        state.start()
        let panel = StatusPanel(content: InteractionView(state: state))
        panel.title = "Recovery Menu Test"
        panel.setContentSize(NSSize(width: 340, height: 180))
        if state.integrated {
            panel.containsPlayerPoint = { _ in true }
            panel.onKeyChanged = { state.presentation.sendAttention(.keyboardFocus($0)) }
            panel.onPointerChanged = { state.presentation.sendAttention(.pointer($0)) }
        }
        panel.makeKeyAndOrderFront(nil)
        if let index = arguments.firstIndex(of: "--check-pending-retry"), index + 1 < arguments.count {
            Task { @MainActor in
                let code = await state.checkPendingRetry(in: panel, changedAction: arguments[index + 1] == "changed")
                exit(code)
            }
        } else {
            app.activate()
        }
        state.snapshot()
        withExtendedLifetime((state, panel)) { app.run() }
    }
}
