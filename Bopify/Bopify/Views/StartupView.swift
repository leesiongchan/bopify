import SwiftUI
import BopifyPlayback

/// Everything before the player on one continuous surface: the record stays put while its pose and the copy change.
struct StartupView<Content: View>: View {
    let step: StartupStep
    var isVisible = true
    @ViewBuilder let content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 20) {
            if let progress = step.progress {
                StartupStepIndicator(current: progress, total: 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            SignInRecordView(step: step, isVisible: isVisible)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background {
                    AuroraBackground(isAnimating: isVisible, isDimmed: step.recordPose == .tucked)
                        .opacity(0.2)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
            // Stacked, so outgoing and incoming copy cross-fade in place instead of pushing each other.
            ZStack {
                content()
                    .id(step.identity)
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

struct StartupStepIndicator: View {
    let current: Int
    let total: Int

    private var name: String {
        switch current {
        case 1: "onboarding.step.account"
        case 2: "onboarding.step.library"
        default: "onboarding.step.playback"
        }
    }

    var body: some View {
        Text("onboarding.step \(current) \(total) \(SoloistResources.string(name))", bundle: SoloistResources.bundle)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("onboarding.step")
    }
}

struct StartupInstruction<Content: View>: View {
    let number: Int
    let title: LocalizedStringKey
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(verbatim: "\(number)")
                .font(.body.weight(.semibold))
                .frame(width: 26, height: 26)
                .background(Color(nsColor: .controlBackgroundColor), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(title, bundle: SoloistResources.bundle)
                    .font(.body.weight(.semibold)).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                content().font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct StartupHeading: View {
    let title: Text
    var message: Text?
    var isCompact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            title.font(.system(isCompact ? .title2 : .title, weight: .semibold))
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)
            if let message {
                message
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct StartupButton: View {
    let key: LocalizedStringKey
    var isSecondary = false
    var identifier = ""
    let action: () -> Void

    var body: some View {
        if isSecondary {
            button.buttonStyle(.glass)
        } else {
            button.buttonStyle(.glassProminent)
        }
    }

    private var button: some View {
        Button(action: action) {
            Text(key, bundle: SoloistResources.bundle)
                .font(.body.weight(isSecondary ? .medium : .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
        }
        .controlSize(.large)
        .accessibilityIdentifier(identifier)
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
