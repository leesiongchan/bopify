import SwiftUI

struct LibraryAuthorizationSetupView: View {
    let environment: AppEnvironment

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "music.note.list")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)
            Text("librarySetup.requiredTitle")
                .font(.system(size: 23, weight: .regular))
            Text("librarySetup.requiredDescription")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let error = environment.librarySetupError {
                error.localizedText.font(.caption).foregroundStyle(.secondary)
            }
            if let notice = environment.libraryAuthorizationNotice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }
            if environment.isAuthorizingLibrary {
                ProgressView { Text("signIn.browser") }.controlSize(.small)
                Button("signIn.cancel", action: environment.cancelLibraryAuthorization)
                    .buttonStyle(.link)
            } else {
                Button("librarySetup.continue") { Task { await environment.completeLibrarySetup() } }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 24)
                    .frame(height: 44)
                    .playerGlass()
            }
            Button("menu.signOut") { Task { await environment.signOut() } }
                .buttonStyle(.link)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
