import SwiftUI
import BopifyPlayback
import BopifyDomain

struct PlaybackConnectionStatusView: View {
    let status: PlaybackConnectionStatus
    let restorationUnavailable: Bool
    let onRetry: () -> Void
    let onReconnect: () -> Void

    var isVisible: Bool { status != .ready && status != .stopped || restorationUnavailable }

    var messageKey: String {
        switch status {
        case .offline: "connection.offline"
        case .needsReauthentication: "connection.reconnect"
        case .ready: "connection.restoreUnavailable"
        case let .failed(error):
            switch error {
            case .premiumRequired: "error.premiumRequired"
            case .authDenied: "error.authDenied"
            case .authExpired: "error.authExpired"
            case .invalidCallback: "error.invalidCallback"
            case .networkUnavailable: "error.networkUnavailable"
            case .playbackSessionLost: "error.playbackSessionLost"
            case .unknown: "error.unknown"
            }
        default: "connection.reconnecting"
        }
    }
    var messageString: String { String(localized: String.LocalizationValue(messageKey)) }
    var message: Text { Text(LocalizedStringKey(messageKey)) }
    var actionKey: String? {
        switch status {
        case .needsReauthentication: "connection.reconnect"
        case .ready where restorationUnavailable: "connection.retryRestoration"
        case .connecting, .restoring, .reconnecting, .offline: "connection.retry"
        default: nil
        }
    }
    func performAction() {
        if status == .needsReauthentication { onReconnect() } else { onRetry() }
    }
    @ViewBuilder var actions: some View {
        if let actionKey { Button(LocalizedStringKey(actionKey), action: performAction) }
    }

    var body: some View {
        if isVisible {
            VStack(alignment: .leading, spacing: 3) {
                message
                actions.buttonStyle(.link)
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// AppKit owns the compact menu's accessibility label and keyboard action together.
struct CompactPlaybackConnectionMenu: NSViewRepresentable {
    let connection: PlaybackConnectionStatusView
    func makeCoordinator() -> Handler { Handler(connection: connection) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.isBordered = false
        button.font = .systemFont(ofSize: 10)
        button.controlSize = .small
        return button
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.connection = connection
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: connection.messageString, action: nil, keyEquivalent: ""))
        if let action = connection.actionKey {
            let item = NSMenuItem(title: String(localized: String.LocalizationValue(action)), action: #selector(Handler.perform(_:)), keyEquivalent: "")
            item.target = context.coordinator
            menu.addItem(item)
        }
        button.menu = menu
        button.setAccessibilityLabel(connection.messageString)
        button.setAccessibilityHelp(connection.messageString)
    }
    final class Handler: NSObject {
        var connection: PlaybackConnectionStatusView
        init(connection: PlaybackConnectionStatusView) { self.connection = connection }
        @objc func perform(_ sender: Any?) { connection.performAction() }
    }
}
