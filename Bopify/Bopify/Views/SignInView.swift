import SwiftUI
import BopifyDomain

enum SignInStatus {
    case idle
    case authenticating
    case error(PlayerError)
}

struct SignInView: View {
    let status: SignInStatus
    let onSignIn: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            ArtworkView(image: nil, diameter: 156)
            VStack(spacing: 6) {
                Group {
                    if case .error = status {
                        Text("signIn.error")
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
            case let .error(error):
                error.localizedText
                    .font(.caption)
                    .foregroundStyle(.primary.opacity(0.7))
                    .multilineTextAlignment(.center)
                signInButton
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var signInButton: some View {
        Button(action: onSignIn) {
            Text("signIn.button")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 24)
                .frame(height: 44)
        }
        .buttonStyle(.plain)
        .playerGlass()
    }
}
