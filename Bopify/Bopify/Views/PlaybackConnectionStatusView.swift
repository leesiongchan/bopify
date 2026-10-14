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
            case .credentialCleanupRequired: "error.credentialCleanupRequired"
            case .credentialCleanupNotRecorded: "error.credentialCleanupNotRecorded"
            case .credentialUnavailable: "error.credentialUnavailable"
            case .credentialAccessDenied: "error.credentialAccessDenied"
            case .credentialCorrupt: "error.credentialCorrupt"
            case .credentialSaveFailed: "error.credentialSaveFailed"
            case .unknown: "error.unknown"
            }
        default: "connection.reconnecting"
        }
    }
    var messageString: String { String(localized: String.LocalizationValue(messageKey)) }
    var message: Text { Text(LocalizedStringKey(messageKey)) }
    var actionKey: String? {
        switch status {
        case .needsReauthentication, .failed(.credentialCorrupt): "connection.reconnect"
        case let .failed(error) where error.canRetryCredentials: "connection.retryCredentials"
        case .ready where restorationUnavailable: "connection.retryRestoration"
        case .connecting, .restoring, .reconnecting, .offline: "connection.retry"
        default: nil
        }
    }
    func performAction() {
        if status == .needsReauthentication || status == .failed(.credentialCorrupt) { onReconnect() } else { onRetry() }
    }
    @ViewBuilder var actions: some View {
        if let actionKey { Button(LocalizedStringKey(actionKey), action: performAction) }
    }

    var body: some View {
        if isVisible {
            HStack(spacing: 8) {
                if messageKey != actionKey {
                    message.lineLimit(1).help(messageString)
                }
                actions.buttonStyle(.link).fixedSize()
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
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return CGSize(width: width, height: proposal.height ?? 24)
    }
    func makeNSView(context: Context) -> NSView {
        // The container allows the compact frame to be narrower than AppKit's intrinsic menu width.
        let container = NSView(frame: .zero)
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.autoresizingMask = [.width, .height]
        button.isBordered = false
        button.font = .systemFont(ofSize: 10)
        button.controlSize = .small
        button.cell?.lineBreakMode = .byTruncatingTail
        button.cell?.usesSingleLineMode = true
        container.addSubview(button)
        return container
    }
    func updateNSView(_ container: NSView, context: Context) {
        let button = container.subviews[0] as! NSPopUpButton
        context.coordinator.connection = connection
        let menu = NSMenu()
        let caption = connection.restorationUnavailable && connection.status == .ready
            ? String(localized: "connection.retry") : connection.messageString
        let title = NSMenuItem(title: caption, action: nil, keyEquivalent: "")
        if case .failed = connection.status {
            title.image = NSImage(systemSymbolName: "exclamationmark.circle", accessibilityDescription: connection.messageString)
        }
        menu.addItem(title)
        if caption != connection.messageString || title.image != nil {
            menu.addItem(NSMenuItem(title: connection.messageString, action: nil, keyEquivalent: ""))
        }
        if let action = connection.actionKey {
            let item = NSMenuItem(title: String(localized: String.LocalizationValue(action)), action: #selector(Handler.performRecoveryAction(_:)), keyEquivalent: "")
            item.target = context.coordinator
            menu.addItem(item)
        }
        button.menu = menu
        if case .failed = connection.status {
            button.imagePosition = .imageOnly
        } else {
            button.imagePosition = .noImage
        }
        button.setAccessibilityLabel(connection.messageString)
        // The observed local menu element is the cell, which otherwise uses the shortened caption.
        button.cell?.setAccessibilityLabel(connection.messageString)
        button.setAccessibilityHelp(connection.messageString)
    }
    final class Handler: NSObject {
        var connection: PlaybackConnectionStatusView
        init(connection: PlaybackConnectionStatusView) { self.connection = connection }
        @objc func performRecoveryAction(_ sender: Any?) { connection.performAction() }
    }
}
