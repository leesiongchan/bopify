import SwiftUI
import BopifyDomain

/// The sign-in button plus the authenticating and error presentations.
enum SignedOutPresentation {
    case idle
    case authenticating
    case error(PlayerError)
}

struct SignedOutView: View {
    let presentation: SignedOutPresentation
    let signIn: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note")
                .font(.largeTitle)
                .foregroundStyle(.secondary)

            switch presentation {
            case .idle:
                Button(action: signIn) { Text("signIn.button") }
            case .authenticating:
                ProgressView {
                    Text("signIn.authenticating")
                }
            case let .error(error):
                VStack(spacing: 4) {
                    Text("signIn.error")
                    error.localizedText
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button(action: signIn) { Text("signIn.button") }
            }
        }
        // No padding here: `MiniPlayerView` already pads its single content
        // area once, inside its fixed-size frame. A second layer here would
        // reintroduce the same overflow this view's sibling doesn't have.
    }
}
