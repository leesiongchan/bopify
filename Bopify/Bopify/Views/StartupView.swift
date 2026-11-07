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
                    .id(step.identity)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6)))
            }
            .frame(maxWidth: .infinity)
            .background {
                StartupReadabilityBackdrop()
                    .padding(.horizontal, -24)
                    .padding(.top, -28)
                    .padding(.bottom, -40)
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
        HStack(spacing: 5) {
            ForEach(1...total, id: \.self) { step in
                Capsule().fill(.primary.opacity(step <= current ? 0.9 : 0.3))
                    .frame(width: 14, height: 4)
            }
        }
        .accessibilityRepresentation {
            Text("onboarding.step \(current) \(total) \(SoloistResources.string(name))", bundle: SoloistResources.bundle)
                .accessibilityIdentifier("onboarding.step")
        }
    }
}

/// A soft tint follows the instructions as they scroll, leaving the Aurora and record visible.
private struct StartupReadabilityBackdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        if !reduceTransparency && contrast != .increased {
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black.opacity(0.42), location: 0.14),
                .init(color: .black.opacity(0.42), location: 1),
            ], startPoint: .top, endPoint: .bottom)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

struct StartupHeading: View {
    let title: Text
    var message: Text?
    var isCompact = false

    var body: some View {
        VStack(spacing: 8) {
            title.font(.system(size: isCompact ? 21 : 24, weight: .semibold))
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)
            if let message {
                message
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 340)
    }
}

struct StartupButton: View {
    let key: LocalizedStringKey
    var isSecondary = false
    var identifier = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(key, bundle: SoloistResources.bundle)
                .font(.body.weight(isSecondary ? .medium : .semibold))
                .padding(.horizontal, isSecondary ? 16 : 24)
                .frame(minHeight: isSecondary ? 32 : 44)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
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
