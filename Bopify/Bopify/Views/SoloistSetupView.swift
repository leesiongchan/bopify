import SwiftUI
import BopifyAuth
import BopifyDomain

struct SoloistSetupView: View {
    let environment: AppEnvironment
    @State private var key = ""
    private var controller: SoloistPlaybackController { environment.soloist }
    private var signedIn: Bool { environment.authState == .signedIn }
    private var busy: Bool {
        if controller.isPreparing { return true }
        switch controller.phase {
        case .authorizing, .installing, .checkingAccount, .pairing, .verifying, .prepared, .reconnecting: return true
        default: return false
        }
    }
    private var providerLabel: String {
        if controller.provider == .soloist { return "soloist.currentSoloist" }
        if busy, controller.prefersSoloist, !controller.sessionUsesLibrespot { return "soloist.preparing" }
        return "soloist.currentLibrespot"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            text("soloist.title").font(.title2.weight(.semibold))
            text("soloist.intro").fixedSize(horizontal: false, vertical: true)
            Label(SoloistResources.string(providerLabel),
                  systemImage: "speaker.wave.2")
                .font(.callout.weight(.medium))
            Divider()
            if !signedIn {
                text("soloist.signInFirst").foregroundStyle(.secondary)
            } else {
                Link(SoloistResources.string("soloist.getKey"), destination: URL(string: "https://developer.spotify.com/dashboard/soloist")!)
                SecureField(SoloistResources.string(controller.hasSavedKey ? "soloist.replaceKey" : "soloist.key"), text: $key)
                    .textFieldStyle(.roundedBorder)
                    .disabled(busy)
                    .accessibilityLabel(SoloistResources.string("soloist.key"))
                    .accessibilityIdentifier("soloist.apiKey")
                    .onSubmit(enable)
                text("soloist.keyPrivacy").font(.caption).foregroundStyle(.secondary)
                status
                HStack {
                    if busy {
                        Button(SoloistResources.string("soloist.cancel")) { Task { await environment.useLibrespotForSession() } }
                    } else {
                        Button(SoloistResources.string(controller.provider == .soloist && key.isEmpty
                            ? "soloist.retryDataServices" : controller.hasSavedKey ? "soloist.retry" : "soloist.enable"), action: enable)
                            .keyboardShortcut(.defaultAction)
                            .disabled(key.isEmpty && !controller.hasSavedKey)
                            .accessibilityIdentifier("soloist.enable")
                    }
                    if controller.phase == .verifying || controller.phase == .reconnecting {
                        Button(SoloistResources.string("soloist.playHere")) { Task { await controller.playHere() } }
                            .accessibilityIdentifier("soloist.playHere")
                    }
                    Spacer()
                }
            }
            Divider()
            text("soloist.queueLimit").font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            text("soloist.switchNotice").font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(SoloistResources.string("soloist.useLibrespot")) { Task { await environment.useLibrespotForSession() } }
                .disabled(!signedIn || environment.isRemovingCredentials || environment.isPreparingForQuit)
                .accessibilityIdentifier("soloist.useLibrespot")
        }
        .padding(24)
        .padding(.top, 20)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .background { PlayerSurface(cornerRadius: 22) { Color.clear } }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .ignoresSafeArea()
        .onDisappear { key = "" }
    }

    @ViewBuilder private var status: some View {
        switch controller.phase {
        case .idle: EmptyView()
        case .authorizing: progress("soloist.authorizing")
        case let .installing(fraction):
            VStack(alignment: .leading, spacing: 8) {
                text("soloist.installing").font(.callout)
                ProgressView(value: fraction).accessibilityLabel(text("soloist.installing"))
            }
        case .checkingAccount: progress("soloist.checkingAccount")
        case let .pairing(name):
            VStack(alignment: .leading, spacing: 8) {
                text("soloist.pairing")
                Text(verbatim: name).font(.headline).textSelection(.enabled)
                text("soloist.pairingHelp").font(.caption).foregroundStyle(.secondary)
            }
        case .verifying:
            progress("soloist.verifying")
            text("soloist.verifyHelp").font(.caption).foregroundStyle(.secondary)
        case .prepared: progress("soloist.adopting")
        case .limitedServices:
            Label(SoloistResources.string("soloist.limitedServices"), systemImage: "info.circle").font(.callout)
        case .ready:
            Label(SoloistResources.string("soloist.ready"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            if controller.hasPendingUpdate { text("soloist.updateReady").font(.caption).foregroundStyle(.secondary) }
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

    private func enable() {
        guard !busy, signedIn else { return }
        let value = key; key = ""
        Task { await environment.enableSoloist(key: value) }
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
        case .rateLimited: "soloist.error.rateLimited"
        }
    }
}
