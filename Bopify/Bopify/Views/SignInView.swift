import SwiftUI
import BopifyDomain

enum SignInStatus {
    case idle
    case authenticating
    case restoring
    case removingCredentials
    case error(PlayerError)
}

struct SignInView: View {
    let status: SignInStatus
    let onSignIn: () -> Void
    var onRetryCredentials: () -> Void = {}
    var onRetryCleanup: () -> Void = {}

    var body: some View {
        VStack(spacing: 18) {
            ArtworkView(image: nil, diameter: 156)
            VStack(spacing: 6) {
                Group {
                    if case let .error(error) = status {
                        Text(LocalizedStringKey((error == .credentialCleanupRequired || error == .credentialCleanupNotRecorded) ? "signIn.cleanupError" :
                                                error.canRetryCredentials || error == .credentialCorrupt ? "signIn.credentialError" : "signIn.error"))
                    } else {
                        Text("signIn.title")
                    }
                }
                    .font(.system(size: 23, weight: .regular))
                Text("signIn.subtitle")
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(0.7))
                    .multilineTextAlignment(.center)
            }

            switch status {
            case .idle:
                signInButton
                Text("signIn.premium")
                    .font(.caption)
                    .foregroundStyle(.primary.opacity(0.7))
            case .authenticating:
                ProgressView { Text("signIn.authenticating") }
                    .controlSize(.small)
                    .font(.callout)
                Text("signIn.browser")
                    .font(.caption)
                    .foregroundStyle(.primary.opacity(0.7))
            case .removingCredentials:
                ProgressView { Text("signIn.removingCredentials") }
                    .controlSize(.small)
                    .font(.callout)
            case .restoring:
                ProgressView { Text("signIn.restoring") }
                    .controlSize(.small)
                    .font(.callout)
            case let .error(error):
                error.localizedText
                    .font(.caption)
                    .foregroundStyle(.primary.opacity(0.7))
                    .multilineTextAlignment(.center)
                if error == .credentialCleanupRequired || error == .credentialCleanupNotRecorded {
                    actionButton("signIn.retryRemoval", action: onRetryCleanup)
                } else if error == .credentialUnavailable || error == .credentialAccessDenied {
                    actionButton("connection.retryCredentials", action: onRetryCredentials)
                } else if error == .credentialCorrupt || error == .credentialSaveFailed {
                    actionButton("signIn.again", action: onSignIn)
                } else {
                    signInButton
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var signInButton: some View {
        actionButton("signIn.button", action: onSignIn)
    }

    private func actionButton(_ key: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(key)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 24)
                .frame(height: 44)
        }
        .buttonStyle(.plain)
        .playerGlass()
    }
}
