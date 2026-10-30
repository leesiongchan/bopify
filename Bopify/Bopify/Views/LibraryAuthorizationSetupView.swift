import SwiftUI

struct LibraryAuthorizationSetupView: View {
    /// A value, not read from the environment, so the copy fading out keeps showing the state it left.
    let status: LibrarySetupStatus
    let environment: AppEnvironment

    /// Named before Spotify's consent page opens, so approving it is not a leap of faith.
    private static let needs: [(symbol: String, key: LocalizedStringKey)] = [
        ("heart.fill", "librarySetup.need.liked"),
        ("star.fill", "librarySetup.need.artists"),
        ("clock.arrow.circlepath", "librarySetup.need.recent"),
        ("plus", "librarySetup.need.likes"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            switch status {
            case .idle:
                StartupHeading(title: Text("librarySetup.requiredTitle"), message: Text("librarySetup.requiredDescription"), isCompact: true)
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Self.needs, id: \.symbol) { need in
                        HStack(spacing: 9) {
                            Image(systemName: need.symbol)
                                .font(.system(size: 10, weight: .semibold))
                                .frame(width: 22, height: 22)
                                .background(.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.primary.opacity(0.25), lineWidth: 0.5))
                                .accessibilityHidden(true)
                            Text(need.key).font(.system(size: 12.5))
                        }
                    }
                }
                .foregroundStyle(.primary.opacity(0.88))
                .padding(.top, 12)
                Text("librarySetup.allRequired")
                    .font(.caption)
                    .foregroundStyle(.primary.opacity(0.7))
                    .padding(.top, 10)
                StartupButton(key: "librarySetup.continue", action: connect).padding(.top, 14)
            case .authorizing:
                StartupHeading(title: Text("librarySetup.authorizing"), message: Text("librarySetup.approveInBrowser"), isCompact: true)
                StartupButton(key: "onboarding.cancel", isSecondary: true, action: environment.cancelLibraryAuthorization)
                    .padding(.top, 16)
            case .refused:
                StartupHeading(title: Text("librarySetup.notConnected"),
                                  message: environment.libraryAuthorizationNotice.map { Text($0) } ?? environment.librarySetupError?.localizedText,
                                  isCompact: true)
                StartupButton(key: "signIn.retry", action: connect).padding(.top, 20)
            }
        }
    }

    private func connect() { Task { await environment.completeLibrarySetup() } }
}
