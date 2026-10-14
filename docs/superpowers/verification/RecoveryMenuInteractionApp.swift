import AppKit
import SwiftUI
import Observation
import BopifyDomain
import BopifyPlayback

@MainActor @Observable private final class InteractionState {
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
    var observers: [NSObjectProtocol] = []
    init(output: URL, integrated: Bool) { self.output = output; self.integrated = integrated }
    var connection: PlaybackConnectionStatusView {
        PlaybackConnectionStatusView(status: status, restorationUnavailable: unavailable,
            onRetry: { self.retries += 1; self.snapshot() },
            onReconnect: { self.reconnects += 1; self.snapshot() })
    }
    func snapshot() {
        let state: [String: Any] = ["retries": retries, "reconnects": reconnects,
            "mode": presentation.mode.rawValue, "menuOpen": menuOpen, "command": lastCommand,
            "keyboardNavigationEnabled": NSApp.isFullKeyboardAccessEnabled]
        try! JSONSerialization.data(withJSONObject: state).write(to: output.appendingPathComponent("state.json"), options: .atomic)
    }
    func command(_ value: String) {
        switch value {
        case "offline": status = .offline; unavailable = false
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
        for (notification, open) in [(NSMenu.didBeginTrackingNotification, true), (NSMenu.didEndTrackingNotification, false)] {
            observers.append(NotificationCenter.default.addObserver(forName: notification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.menuOpen = open; self?.snapshot() }
            })
        }
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
        app.activate()
        state.snapshot()
        withExtendedLifetime((state, panel)) { app.run() }
    }
}
