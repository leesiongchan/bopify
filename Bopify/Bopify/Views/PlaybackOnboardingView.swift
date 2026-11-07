import SwiftUI
import BopifyAuth
import BopifyDomain

struct PlaybackOnboardingView: View {
    let environment: AppEnvironment
    @State private var key = ""
    private var controller: SoloistPlaybackController { environment.soloist }
    private var busy: Bool {
        if controller.isPreparing { return true }
        return switch controller.phase {
        case .authorizing, .installing, .checkingAccount, .pairing, .verifying, .prepared, .reconnecting: true
        default: false
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            StartupHeading(title: text("onboarding.playbackTitle"),
                           message: text("onboarding.playbackDescription"), isCompact: true)
            if !busy {
                Link(SoloistResources.string("soloist.getKey"), destination: URL(string: "https://developer.spotify.com/dashboard/soloist")!)
                    .font(.callout)
                SecureField(SoloistResources.string(controller.hasSavedKey ? "soloist.replaceKey" : "soloist.key"), text: $key)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(SoloistResources.string("soloist.key"))
                    .accessibilityIdentifier("soloist.apiKey")
                    .onSubmit(enable)
                text("soloist.keyPrivacy").font(.caption).foregroundStyle(.secondary)
            }
            status
            if busy {
                StartupButton(key: "onboarding.listenWithLibrespot", isSecondary: true, identifier: "soloist.useLibrespot", action: fallback)
            } else {
                StartupButton(key: controller.hasUsablePlayback && key.isEmpty ? "soloist.retryDataServices"
                              : controller.hasSavedKey ? "soloist.retry" : "onboarding.startListening",
                              identifier: "soloist.enable", action: enable)
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !controller.hasSavedKey)
                if case .failed = controller.phase {
                    StartupButton(key: "onboarding.listenWithLibrespot", isSecondary: true, identifier: "soloist.useLibrespot", action: fallback)
                }
            }
            Button(SoloistResources.string("onboarding.library")) { environment.showOnboarding(section: .library) }
                .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("onboarding.library")
        }
        .frame(maxWidth: 340)
        .multilineTextAlignment(.center)
        .onDisappear { key = "" }
        .onChange(of: controller.provider) { _, provider in
            if provider == .soloist { environment.closeOnboarding() }
        }
    }

    @ViewBuilder private var status: some View {
        switch controller.phase {
        case .idle: EmptyView()
        case .authorizing: progress("soloist.authorizing")
        case let .installing(fraction):
            VStack(spacing: 8) {
                text("soloist.installing").font(.callout)
                ProgressView(value: fraction).accessibilityLabel(text("soloist.installing"))
            }
        case .checkingAccount: progress("soloist.checkingAccount")
        case let .pairing(name):
            VStack(spacing: 8) {
                text("soloist.pairing").font(.callout)
                Text(verbatim: name).font(.headline).textSelection(.enabled)
                text("soloist.pairingHelp").font(.caption).foregroundStyle(.secondary)
                Link("onboarding.openSpotify", destination: URL(string: "https://open.spotify.com")!)
            }
        case .verifying:
            progress("soloist.verifying")
            text("soloist.verifyHelp").font(.caption).foregroundStyle(.secondary)
            Button(SoloistResources.string("soloist.playHere")) { Task { await controller.playHere() } }
                .accessibilityIdentifier("soloist.playHere")
        case .prepared: progress("soloist.adopting")
        case .limitedServices:
            Label(SoloistResources.string("soloist.limitedServices"), systemImage: "info.circle").font(.caption)
        case .ready:
            Label(SoloistResources.string("soloist.ready"), systemImage: "checkmark.circle").font(.callout)
        case .reconnecting: progress("soloist.reconnecting")
        case let .failed(failure):
            text(failure.message).foregroundStyle(.red).font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func text(_ key: LocalizedStringKey) -> Text { Text(key, bundle: SoloistResources.bundle) }
    private func progress(_ key: LocalizedStringKey) -> some View {
        HStack(spacing: 10) { ProgressView().controlSize(.small); text(key).font(.callout) }
    }
    private func fallback() {
        Task { await environment.useLibrespotForSession(); environment.closeOnboarding() }
    }
    private func enable() {
        guard !busy else { return }
        let value = key; key = ""
        Task {
            await environment.enableSoloist(key: value)
            if controller.provider == .soloist { environment.closeOnboarding() }
        }
    }
}

extension SoloistSetupFailure {
    var message: LocalizedStringKey {
        switch self {
        case .invalidKey: "soloist.error.invalidKey"
        case .credentials: "soloist.error.credentials"
        case .authorization: "soloist.error.authorization"
        case .accountMismatch: "soloist.error.accountMismatch"
        case .missingAccountID: "soloist.error.missingAccountID"
        case .pairing: "soloist.error.pairing"
        case .installation: "soloist.error.installation"
        case .startup: "soloist.error.startup"
        case .processInUse: "soloist.error.processInUse"
        case .storage: "soloist.error.storage"
        case .launch: "soloist.error.launch"
        case .endpoint: "soloist.error.endpoint"
        case .rateLimited: "soloist.error.rateLimited"
        }
    }
}
