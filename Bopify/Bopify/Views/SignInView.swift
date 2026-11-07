import SwiftUI
import BopifyDomain

enum SignInStatus: Hashable {
    case idle
    case authenticating
    case restoring
    case removingCredentials
    case error(PlayerError)
}

struct SignInView: View {
    let status: SignInStatus
    let onSignIn: () -> Void
    /// Nil when there's no sign-in to cancel, such as while the player starts after one succeeds.
    var onCancel: (() -> Void)?
    var onRetryCredentials: () -> Void = {}
    var onRetryCleanup: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            switch status {
            case .idle:
                StartupHeading(title: Text("signIn.title", bundle: SoloistResources.bundle), message: Text("signIn.subtitle", bundle: SoloistResources.bundle))
                StartupButton(key: "signIn.button", action: onSignIn).padding(.top, 20)
                Text("signIn.premium", bundle: SoloistResources.bundle)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .padding(.top, 12)
            case .authenticating:
                StartupHeading(title: Text("onboarding.signingIn", bundle: SoloistResources.bundle), message: Text("signIn.browser", bundle: SoloistResources.bundle))
                if let onCancel {
                    StartupButton(key: "onboarding.cancel", isSecondary: true, action: onCancel).padding(.top, 16)
                }
            case .removingCredentials:
                StartupHeading(title: Text("signIn.removingCredentials", bundle: SoloistResources.bundle))
            case .restoring:
                StartupHeading(title: Text("signIn.restoring", bundle: SoloistResources.bundle))
            case let .error(error):
                let isCleanup = error == .credentialCleanupRequired || error == .credentialCleanupNotRecorded
                StartupHeading(title: Text(LocalizedStringKey(isCleanup ? "signIn.cleanupError" :
                                                                 error.canRetryCredentials || error == .credentialCorrupt ? "signIn.credentialError" : "signIn.error")),
                                  message: error.localizedText)
                Group {
                    if isCleanup {
                        StartupButton(key: "signIn.retryRemoval", action: onRetryCleanup)
                    } else if error == .credentialUnavailable || error == .credentialAccessDenied {
                        StartupButton(key: "connection.retryCredentials", action: onRetryCredentials)
                    } else if error == .credentialCorrupt || error == .credentialSaveFailed {
                        StartupButton(key: "signIn.again", action: onSignIn)
                    } else {
                        StartupButton(key: "signIn.retry", action: onSignIn)
                    }
                }
                .padding(.top, 20)
            }
        }
        .frame(maxWidth: 340)
        .multilineTextAlignment(.center)
    }
}
