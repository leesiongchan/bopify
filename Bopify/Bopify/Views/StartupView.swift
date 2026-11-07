import SwiftUI
import BopifyPlayback

/// Everything before the player on one continuous surface: the record stays put while its pose and the copy change.
struct StartupView<Content: View>: View {
    let step: StartupStep
    var isVisible = true
    var onRecordFrameChanged: ((CGRect) -> Void)?
    @ViewBuilder let content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            // Reserve the same readable form area at every step; adapt artwork only to the viewport.
            let scale = min(0.88, max(0.25, (geometry.size.height - 312 - 18) / 324))
            VStack(spacing: 18) {
                SignInRecordView(step: step, isVisible: isVisible,
                                 onRecordFrameChanged: onRecordFrameChanged, scale: scale)
                    .overlay(alignment: .bottomTrailing) {
                        if step == .completion {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 24, weight: .medium))
                                .foregroundStyle(.green)
                                .symbolRenderingMode(.hierarchical)
                                .accessibilityHidden(true)
                                .transition(.opacity)
                        }
                    }
                // Stacked, so outgoing and incoming copy cross-fade in place instead of pushing each other.
                ZStack {
                    content()
                        .id(step.contentIdentity)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6)))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(maxHeight: .infinity)
            .animation(.easeInOut(duration: reduceMotion ? 0.16 : 0.3), value: step)
        }
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

struct StartupHeading: View {
    let title: Text
    var message: Text?
    var isCompact = false

    var body: some View {
        VStack(spacing: 8) {
            title.font(.system(size: isCompact ? 21 : 24, weight: .semibold))
                .startupPrimary()
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("onboarding.title")
            if let message {
                message
                    .font(.body)
                    .startupSupporting()
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
        .startupActionGlass()
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
