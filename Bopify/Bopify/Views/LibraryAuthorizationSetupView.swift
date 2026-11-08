import AppKit
import SwiftUI
import BopifyAuth
import BopifyDomain

/// Registration and consent stay on the same surface as sign-in and playback setup.
struct LibraryAuthorizationSetupView: View {
    private static let needs: [(symbol: String, key: String, identifier: String)] = [
        ("heart.fill", "librarySetup.need.liked", "liked"),
        ("star.fill", "librarySetup.need.artists", "artists"),
        ("clock.arrow.circlepath", "librarySetup.need.recent", "recent"),
        ("plus", "librarySetup.need.likes", "likes"),
    ]
    let status: LibrarySetupStatus
    let environment: AppEnvironment
    @State private var clientID = ""
    @State private var isEditingClient = false
    @State private var isSaving = false
    @State private var showsRegistrationHelp = false
    @FocusState private var clientIDFocused: Bool

    private var needsRegistration: Bool { environment.libraryClientID == nil || isEditingClient }
    private var validClient: Bool { LibraryAuthorization.normalized(clientID) != nil }

    var body: some View {
        VStack(spacing: 14) {
            if showsRegistrationHelp {
                registrationHelp
            } else if status == .connected {
                StartupHeading(title: Text("librarySetup.connected", bundle: SoloistResources.bundle),
                               message: Text("librarySetup.connectedDescription", bundle: SoloistResources.bundle), isCompact: true)
                Label(SoloistResources.string("onboarding.continuing"), systemImage: "checkmark.circle")
                    .font(.callout).startupSupporting()
            } else if status == .authorizing {
                StartupHeading(title: Text("librarySetup.authorizing", bundle: SoloistResources.bundle),
                               message: Text("librarySetup.approveInBrowser", bundle: SoloistResources.bundle), isCompact: true)
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("onboarding.waitingForSpotify", bundle: SoloistResources.bundle).font(.callout)
                }
                .startupStatus()
            } else {
                StartupHeading(title: Text("librarySetup.requiredTitle", bundle: SoloistResources.bundle),
                               message: Text("librarySetup.registrationIntro", bundle: SoloistResources.bundle), isCompact: true)
                permissions
                if needsRegistration {
                    registration
                } else {
                    if status == .refused { failure }
                    if environment.authState == .needsLibraryAuthorization {
                        StartupButton(key: status == .refused ? "signIn.retry" : "librarySetup.continue", action: connect)
                    } else {
                        Label(SoloistResources.string("librarySetup.connected"), systemImage: "checkmark.circle")
                            .font(.callout).startupSupporting()
                    }
                    Button(SoloistResources.string("librarySetup.editRegistration")) { isEditingClient = true }
                        .buttonStyle(.plain).font(.callout).foregroundStyle(.tint)
                        .accessibilityIdentifier("onboarding.editLibrary")
                }
            }
        }
        .frame(maxWidth: 340)
        .multilineTextAlignment(.center)
        .onAppear { clientID = environment.libraryClientID ?? "" }
    }

    private var registration: some View {
        VStack(spacing: 14) {
            StartupInput(label: "librarySetup.clientID", identifier: "onboarding.libraryClientID", isFocused: clientIDFocused, onActivate: { clientIDFocused = true }) {
                TextField(SoloistResources.string("librarySetup.clientIDPlaceholder"), text: $clientID)
                    .font(.system(.body, design: .monospaced))
                    .focused($clientIDFocused)
                    .accessibilityLabel(SoloistResources.string("librarySetup.clientID"))
                    .accessibilityIdentifier("onboarding.libraryClientID")
                    .onSubmit(save)
                    .disabled(isSaving)
            }
            Button(SoloistResources.string("librarySetup.getClientID")) {
                withAnimation(.easeInOut(duration: 0.2)) { showsRegistrationHelp = true }
            }
            .buttonStyle(.plain).font(.callout).foregroundStyle(.tint)
            .accessibilityIdentifier("onboarding.registrationHelp")
            if !clientID.isEmpty && !validClient {
                Text("librarySetup.invalid", bundle: SoloistResources.bundle).font(.callout).startupStatus()
            }
            failure
            StartupButton(key: "librarySetup.saveAndContinue", identifier: "onboarding.saveLibrary", action: save)
                .disabled(!validClient || isSaving)
            Text("librarySetup.consentHint", bundle: SoloistResources.bundle).font(.callout).startupSupporting()
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Self.needs, id: \.identifier) { need in
                HStack(spacing: 9) {
                    Image(systemName: need.symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .background(.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.primary.opacity(0.25), lineWidth: 0.5))
                        .accessibilityHidden(true)
                    Text(SoloistResources.string(need.key))
                        .font(.system(size: 12.5))
                        .accessibilityIdentifier("onboarding.permission.\(need.identifier)")
                }
            }
            Text("librarySetup.allRequired", bundle: SoloistResources.bundle)
                .font(.caption)
                .padding(.top, 3)
        }
        .startupSupporting()
        .frame(maxWidth: .infinity, alignment: .center)
        .multilineTextAlignment(.leading)
    }

    private var registrationHelp: some View {
        VStack(spacing: 12) {
            StartupHeading(title: Text("librarySetup.getClientID", bundle: SoloistResources.bundle), isCompact: true)
            Text("librarySetup.guide.createDetail", bundle: SoloistResources.bundle)
            StartupButton(key: "librarySetup.openDashboard", identifier: "onboarding.openDashboard") {
                NSWorkspace.shared.open(URL(string: "https://developer.spotify.com/dashboard")!)
            }
            Text("librarySetup.guide.redirectDetail", bundle: SoloistResources.bundle)
            Text(verbatim: LibraryAuthorization.redirectURI)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityRepresentation {
                    Text(verbatim: LibraryAuthorization.redirectURI)
                        .accessibilityIdentifier("onboarding.redirectURI")
                }
            Button(SoloistResources.string("librarySetup.copy")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(LibraryAuthorization.redirectURI, forType: .string)
            }
            .buttonStyle(.plain).foregroundStyle(.tint)
            .accessibilityIdentifier("onboarding.copyRedirect")
            Text("librarySetup.guide.connectDetail", bundle: SoloistResources.bundle)
                .fixedSize(horizontal: false, vertical: true)
            Button(SoloistResources.string("librarySetup.backToLibrary")) {
                withAnimation(.easeInOut(duration: 0.2)) { showsRegistrationHelp = false }
            }
            .buttonStyle(.plain).foregroundStyle(.tint)
            .accessibilityIdentifier("onboarding.registrationBack")
        }
        .font(.callout).startupSupporting()
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
