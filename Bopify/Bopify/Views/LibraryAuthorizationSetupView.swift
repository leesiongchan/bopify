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
    @FocusState private var clientIDFocused: Bool

    private var needsRegistration: Bool { environment.libraryClientID == nil || isEditingClient }
    private var validClient: Bool { LibraryAuthorization.normalized(clientID) != nil }

    var body: some View {
        VStack(spacing: 14) {
            StartupHeading(title: Text("librarySetup.requiredTitle", bundle: SoloistResources.bundle),
                           message: Text(needsRegistration ? "librarySetup.registrationIntro" : "librarySetup.requiredDescription", bundle: SoloistResources.bundle),
                           isCompact: true)
            if status == .authorizing {
                Text("librarySetup.approveInBrowser", bundle: SoloistResources.bundle).font(.body)
                StartupButton(key: "onboarding.cancel", isSecondary: true, action: environment.cancelLibraryAuthorization)
            } else if needsRegistration {
                registration
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Label(SoloistResources.string("librarySetup.need.liked"), systemImage: "heart")
                    Label(SoloistResources.string("librarySetup.need.artists"), systemImage: "star")
                    Label(SoloistResources.string("librarySetup.need.recent"), systemImage: "clock.arrow.circlepath")
                    Label(SoloistResources.string("librarySetup.need.likes"), systemImage: "plus")
                }
                .font(.body)
                if status == .refused { failure }
                if environment.authState == .needsLibraryAuthorization {
                    StartupButton(key: status == .refused ? "signIn.retry" : "librarySetup.continue", action: connect)
                } else {
                    Label(SoloistResources.string("librarySetup.connected"), systemImage: "checkmark.circle").font(.callout)
                }
                Button(SoloistResources.string("librarySetup.editRegistration")) { isEditingClient = true }
                    .buttonStyle(.plain).font(.callout)
                    .accessibilityIdentifier("onboarding.editLibrary")
            }
            if environment.authState == .signedIn {
                Button(SoloistResources.string("onboarding.playback")) { environment.showOnboarding(section: .playback) }
                    .buttonStyle(.plain).font(.callout)
                    .accessibilityIdentifier("onboarding.playback")
            }
        }
        .frame(maxWidth: 340)
        .multilineTextAlignment(.center)
        .onAppear { clientID = environment.libraryClientID ?? "" }
    }

    private var registration: some View {
        VStack(spacing: 14) {
            Text("librarySetup.guide.createDetail", bundle: SoloistResources.bundle)
                .fixedSize(horizontal: false, vertical: true)
            Link(SoloistResources.string("librarySetup.openDashboard"),
                 destination: URL(string: "https://developer.spotify.com/dashboard")!)
                .foregroundStyle(.tint)
            Text("librarySetup.guide.redirectDetail", bundle: SoloistResources.bundle)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 8) {
                Text(verbatim: LibraryAuthorization.redirectURI)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("onboarding.redirectURI")
                Button(SoloistResources.string("librarySetup.copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(LibraryAuthorization.redirectURI, forType: .string)
                }
                .accessibilityIdentifier("onboarding.copyRedirect")
            }
            Text("librarySetup.guide.connectDetail", bundle: SoloistResources.bundle)
                .fixedSize(horizontal: false, vertical: true)
            StartupInput(label: "librarySetup.clientID", labelIdentifier: "onboarding.clientIDLabel",
                         isFocused: clientIDFocused, onActivate: { clientIDFocused = true }) {
                TextField(SoloistResources.string("librarySetup.clientIDPlaceholder"), text: $clientID)
                    .font(.system(.body, design: .monospaced))
                    .focused($clientIDFocused)
                    .accessibilityLabel(SoloistResources.string("librarySetup.clientID"))
                    .accessibilityIdentifier("onboarding.libraryClientID")
                    .onSubmit(save)
                    .disabled(isSaving)
            }
            if !clientID.isEmpty && !validClient {
                Text("librarySetup.invalid", bundle: SoloistResources.bundle)
                    .font(.callout)
            }
            failure
            StartupButton(key: "librarySetup.saveAndContinue", identifier: "onboarding.saveLibrary", action: save)
                .disabled(!validClient || isSaving)
            if environment.libraryClientID != nil {
                Button(SoloistResources.string("onboarding.cancel")) {
                    isEditingClient = false
                    clientID = environment.libraryClientID ?? ""
                }
                .buttonStyle(.plain).font(.body)
            }
        }
        .font(.body)
    }

    @ViewBuilder private var failure: some View {
        if let notice = environment.libraryAuthorizationNotice {
            Text(verbatim: notice).font(.callout).foregroundStyle(.red)
        } else if let error = environment.librarySetupError {
            error.localizedText.font(.callout).foregroundStyle(.red)
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
