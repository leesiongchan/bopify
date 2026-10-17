import SwiftUI
import BopifyPlayback
import BopifyDomain

struct PlaybackConnectionStatusView: View {
    let status: PlaybackConnectionStatus
    let restorationUnavailable: Bool
    let onRetry: () -> Void
    let onReconnect: () -> Void
    var isAuthorizing = false
    var onCancel: () -> Void = {}

    var isVisible: Bool { status != .ready && status != .stopped || restorationUnavailable }

    var messageKey: String {
        if isAuthorizing { return "signIn.authenticating" }
        return switch status {
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
        if isAuthorizing { return "signIn.cancel" }
        return switch status {
        case .needsReauthentication, .failed(.credentialCorrupt): "connection.reconnect"
        case let .failed(error) where error.canRetryCredentials: "connection.retryCredentials"
        case .ready where restorationUnavailable: "connection.retryRestoration"
        case .connecting, .restoring, .reconnecting, .offline: "connection.retry"
        default: nil
        }
    }
    func performAction() {
        if isAuthorizing { onCancel() }
        else if status == .needsReauthentication || status == .failed(.credentialCorrupt) { onReconnect() }
        else { onRetry() }
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

struct CompactPlaybackConnectionMenu: View {
    let connection: PlaybackConnectionStatusView

    var body: some View {
        Menu {
            if connection.messageKey != connection.actionKey { connection.message }
            connection.actions
        } label: {
            HStack(spacing: 3) {
                if case .failed = connection.status {
                    Image(systemName: "exclamationmark.circle")
                } else {
                    Text(connection.restorationUnavailable && connection.status == .ready
                        ? String(localized: "connection.retry") : connection.messageString)
                        .lineLimit(1).truncationMode(.tail)
                }
                Image(systemName: "chevron.down").font(.system(size: 6, weight: .bold)).opacity(0.6)
            }
            .font(.system(size: 10))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        // Keep a pending selection attached to its original command when recovery changes.
        .id(connection.actionKey)
        .accessibilityLabel(Text(connection.messageString))
        .help(connection.messageString)
    }
}
