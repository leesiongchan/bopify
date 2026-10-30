import SwiftUI
import BopifyPlayback

/// Everything before the player on one continuous surface: the record stays put while its pose and the copy change.
struct StartupView<Content: View>: View {
    let step: StartupStep
    var isVisible = true
    @ViewBuilder let content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 18) {
            SignInRecordView(step: step, isVisible: isVisible)
            // Stacked, so outgoing and incoming copy cross-fade in place instead of pushing each other.
            ZStack {
                content()
                    .id(step)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6)))
            }
        }
        .frame(maxHeight: .infinity)
        .animation(.easeInOut(duration: reduceMotion ? 0.16 : 0.3), value: step)
    }
}

extension AppEnvironment {
    var librarySetupStatus: LibrarySetupStatus {
        if isAuthorizingLibrary { .authorizing }
        else if librarySetupError != nil || libraryAuthorizationNotice != nil { .refused }
        else { .idle }
    }
}

struct StartupStepPips: View {
    let current: Int
    let total: Int

    var body: some View {
        HStack(spacing: 5) {
            ForEach(1...total, id: \.self) { step in
                Capsule().fill(.primary.opacity(step <= current ? 0.9 : 0.25))
                    .frame(width: 14, height: 4)
            }
        }
        .animation(.easeInOut(duration: 0.5), value: current)
        .accessibilityElement()
        .accessibilityLabel(Text("onboarding.progress \(current) \(total)"))
    }
}

struct StartupHeading: View {
    let title: Text
    var message: Text?
    var isCompact = false

    var body: some View {
        VStack(spacing: 6) {
            title.font(.system(size: isCompact ? 21 : 24, weight: .semibold))
            if let message {
                message
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 300)
    }
}

struct StartupButton: View {
    let key: LocalizedStringKey
    var isSecondary = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(key)
                .font(.system(size: isSecondary ? 12 : 13, weight: isSecondary ? .medium : .semibold))
                .padding(.horizontal, isSecondary ? 16 : 24)
                .frame(height: isSecondary ? 30 : 44)
        }
        .buttonStyle(.plain)
        .playerGlass()
    }
}

extension PlaybackConnectionStatusView {
    /// Trouble the user has to act on, as opposed to work still in progress.
    var isFailure: Bool {
        guard !isAuthorizing else { return false }
        return switch status {
        case .offline, .failed, .needsReauthentication: true
        case .ready: restorationUnavailable
        case .connecting, .restoring, .reconnecting, .stopped: false
        }
    }
}

/// Uses the connection line's own wording and actions, so it says the same thing wherever the status appears.
struct StartupConnectionView: View {
    let connection: PlaybackConnectionStatusView

    var body: some View {
        VStack(spacing: 0) {
            // When the action already names the problem, as "Reconnect Spotify" does, a matching title would stutter.
            StartupHeading(title: connection.messageKey == connection.actionKey ? Text("connection.sessionEnded") : connection.message)
            if let actionKey = connection.actionKey {
                StartupButton(key: LocalizedStringKey(actionKey), isSecondary: !connection.isFailure, action: connection.performAction)
                    .padding(.top, 16)
            }
        }
    }
}
