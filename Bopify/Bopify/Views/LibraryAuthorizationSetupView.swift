import AppKit
import SwiftUI
import BopifyAuth
import BopifyDomain

/// Registration and consent stay on the same surface as sign-in and playback setup.
struct LibraryAuthorizationSetupView: View {
    let status: LibrarySetupStatus
    let environment: AppEnvironment
    @State private var clientID = ""
    @State private var isEditingClient = false
    @State private var isSaving = false

    private var needsRegistration: Bool { environment.libraryClientID == nil || isEditingClient }
    private var validClient: Bool { LibraryAuthorization.normalized(clientID) != nil }

    var body: some View {
        VStack(spacing: 14) {
            StartupHeading(title: Text("librarySetup.requiredTitle"),
                           message: Text(needsRegistration ? "librarySetup.registrationIntro" : "librarySetup.requiredDescription"),
                           isCompact: true)
            if status == .authorizing {
                Text("librarySetup.approveInBrowser").font(.callout).foregroundStyle(.secondary)
                StartupButton(key: "onboarding.cancel", isSecondary: true, action: environment.cancelLibraryAuthorization)
            } else if needsRegistration {
                registration
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Label("librarySetup.need.liked", systemImage: "heart")
                    Label("librarySetup.need.artists", systemImage: "star")
                    Label("librarySetup.need.recent", systemImage: "clock.arrow.circlepath")
                    Label("librarySetup.need.likes", systemImage: "plus")
                }
                .font(.callout).foregroundStyle(.secondary)
                if status == .refused { failure }
                if environment.authState == .needsLibraryAuthorization {
                    StartupButton(key: status == .refused ? "signIn.retry" : "librarySetup.continue", action: connect)
                } else {
                    Label("librarySetup.connected", systemImage: "checkmark.circle").font(.callout)
                }
                Button("librarySetup.editRegistration") { isEditingClient = true }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("onboarding.editLibrary")
            }
            if environment.authState == .signedIn {
                Button(SoloistResources.string("onboarding.playback")) { environment.showOnboarding(section: .playback) }
                    .buttonStyle(.plain).font(.caption)
                    .accessibilityIdentifier("onboarding.playback")
            }
        }
        .frame(maxWidth: 340)
        .onAppear { clientID = environment.libraryClientID ?? "" }
    }

    private var registration: some View {
        VStack(alignment: .leading, spacing: 10) {
            Link("librarySetup.openDashboard", destination: URL(string: "https://developer.spotify.com/dashboard")!)
            Text("librarySetup.registrationInstructions").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(verbatim: LibraryAuthorization.redirectURI)
                    .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                Spacer(minLength: 0)
                Button("librarySetup.copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(LibraryAuthorization.redirectURI, forType: .string)
                }.font(.caption)
            }
            Text("librarySetup.step3").font(.caption).foregroundStyle(.secondary)
            TextField("librarySetup.clientID", text: $clientID)
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))
                .accessibilityIdentifier("onboarding.libraryClientID")
                .onSubmit(save)
                .disabled(isSaving)
            if !clientID.isEmpty && !validClient {
                Text("librarySetup.invalid").font(.caption).foregroundStyle(.secondary)
            }
            failure
            HStack {
                Spacer()
                StartupButton(key: "librarySetup.saveAndContinue", identifier: "onboarding.saveLibrary", action: save)
                    .disabled(!validClient || isSaving)
                Spacer()
            }
            if environment.libraryClientID != nil {
                Button("onboarding.cancel") { isEditingClient = false; clientID = environment.libraryClientID ?? "" }
                    .buttonStyle(.plain).font(.caption).frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder private var failure: some View {
        if let notice = environment.libraryAuthorizationNotice {
            Text(verbatim: notice).font(.caption).foregroundStyle(.red)
        } else if let error = environment.librarySetupError {
            error.localizedText.font(.caption).foregroundStyle(.red)
        }
    }

    private func connect() { Task { await environment.completeLibrarySetup() } }

    private func save() {
        guard validClient, !isSaving else { return }
        isSaving = true
        Task {
            await environment.setLibraryClientID(clientID)
            isSaving = false
            if environment.librarySetupError == nil { isEditingClient = false }
        }
    }
}
