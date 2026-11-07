import AppKit
import SwiftUI
import BopifyAuth
import BopifyDomain

struct PlaybackOnboardingView: View {
    let environment: AppEnvironment
    @State private var key = ""
    @FocusState private var keyFocused: Bool
    @State private var discovery: SoloistDiscovery
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var controller: SoloistPlaybackController { environment.soloist }
    private var scene: PlaybackOnboardingScene { PlaybackOnboardingScene(phase: controller.phase) }
    private var busy: Bool { controller.isPreparing || scene != .entry }
    private var monitorsDiscovery: Bool { scene == .pairing }
    private var copy: PlaybackOnboardingCopy { PlaybackOnboardingCopy(phase: controller.phase) }

    init(environment: AppEnvironment, discovery: SoloistDiscovery = SoloistDiscovery()) {
        self.environment = environment
        _discovery = State(initialValue: discovery)
    }

    var body: some View {
        ZStack {
            VStack(spacing: 14) {
                if monitorsDiscovery && discovery.state == .denied {
                    StartupHeading(title: text("onboarding.permissionTitle"),
                                   message: text("onboarding.permissionDescription"), isCompact: true)
                } else {
                    StartupHeading(title: text(LocalizedStringKey(copy.title)),
                                   message: copy.message.isEmpty ? nil : text(LocalizedStringKey(copy.message)), isCompact: true)
                }
                switch scene {
                case .entry: entry
                case .preparing: preparation
                case .pairing: pairing
                case .connecting: progress("onboarding.finishingConnection")
                case .ready:
                    Label(SoloistResources.string("soloist.ready"), systemImage: "checkmark.circle")
                        .font(.callout).startupSupporting()
                }
            }
            .id(scene)
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 5)))
        }
        .frame(maxWidth: 340)
        .multilineTextAlignment(.center)
        .animation(.easeInOut(duration: reduceMotion ? 0.16 : 0.26), value: scene)
        .task(id: monitorsDiscovery) {
            if monitorsDiscovery {
                discovery.start(onRecovery: requestDiscoveryRecovery)
            } else { discovery.stop() }
        }
        .onChange(of: controller.phase) { _, phase in
            if phase == .failed(.discovery) { requestDiscoveryRecovery() }
        }
        .onChange(of: discovery.isReady, initial: true) { _, isReady in
            if isReady { requestDiscoveryRecovery() }
        }
        .onDisappear { key = ""; discovery.stop() }
    }

    private var entry: some View {
        VStack(spacing: 14) {
            StartupInput(label: "soloist.key", identifier: "soloist.apiKey", isFocused: keyFocused, onActivate: { keyFocused = true }) {
                SecureField(SoloistResources.string(controller.hasSavedKey ? "soloist.savedKeyPlaceholder" : "soloist.keyPlaceholder"), text: $key)
                    .focused($keyFocused)
                    .accessibilityLabel(SoloistResources.string("soloist.key"))
                    .accessibilityIdentifier("soloist.apiKey")
                    .onSubmit(enable)
            }
            Link(SoloistResources.string("soloist.getKey"), destination: URL(string: "https://developer.spotify.com/dashboard/soloist")!)
                .font(.callout).foregroundStyle(.tint)
            if controller.hasSavedKey {
                text("soloist.savedKeyHint").font(.callout).startupSupporting()
                    .fixedSize(horizontal: false, vertical: true)
            }
            if case let .failed(failure) = controller.phase {
                text(failure.message).foregroundStyle(.red).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            StartupButton(key: controller.hasUsablePlayback && key.isEmpty ? "soloist.retryDataServices"
                          : controller.hasSavedKey ? "soloist.retry" : "onboarding.startListening",
                          identifier: "soloist.enable", action: enable)
                .disabled(busy || (key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !controller.hasSavedKey))
            text("soloist.keyPrivacy").font(.callout).startupSupporting()
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var preparation: some View {
        if case let .installing(fraction) = controller.phase {
            ProgressView(value: fraction).frame(maxWidth: 190)
                .accessibilityLabel(text("soloist.installing"))
                .tint(.accentColor)
        } else {
            progress("soloist.installing")
        }
    }

    private var pairing: some View {
        VStack(spacing: 14) {
            if discovery.state != .denied, case let .pairing(name) = controller.phase {
                Label { Text(verbatim: name).textSelection(.enabled) } icon: { Image(systemName: "hifispeaker") }
                    .font(.headline).startupSupporting()
            }
            SoloistPairingGuidance(state: discovery.state, isConnectionUnavailable: controller.phase == .failed(.discovery),
                isRecovering: environment.isRestartingSoloistPairing, openSettings: Self.openLocalNetworkSettings, openSpotify: Self.openDesktopSpotify)
        }
    }

    private static func openLocalNetworkSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!)
    }

    private static func openDesktopSpotify() {
        let download = URL(string: "https://www.spotify.com/download/")!
        guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") else {
            NSWorkspace.shared.open(download)
            return
        }
        Task {
            do { _ = try await NSWorkspace.shared.openApplication(at: application, configuration: .init()) }
            catch { NSWorkspace.shared.open(download) }
        }
    }

    private func text(_ key: LocalizedStringKey) -> Text { Text(key, bundle: SoloistResources.bundle) }
    private func progress(_ key: LocalizedStringKey) -> some View {
        HStack(spacing: 10) { ProgressView().controlSize(.small); text(key).font(.callout) }
            .startupStatus()
    }
    private func requestDiscoveryRecovery() {
        Task {
            guard discovery.isReady, discovery.state == .browsing else { return }
            await environment.resumeSoloistDiscovery()
        }
    }

    private func enable() {
        guard !busy else { return }
        let value = key; key = ""
        Task { await environment.enableSoloist(key: value) }
    }
}

/// Progress fractions and entry failures keep their native controls and focus identity.
enum PlaybackOnboardingScene: Hashable {
    case entry, preparing, pairing, connecting, ready

    init(phase: SoloistSetupPhase) {
        self = switch phase {
        case .idle: .entry
        case .failed(.discovery): .pairing
        case .failed: .entry
        case .pairing: .pairing
        case .verifying, .prepared, .reconnecting: .connecting
        case .ready, .limitedServices: .ready
        case .authorizing, .installing, .checkingAccount: .preparing
        }
    }
}

struct PlaybackOnboardingCopy {
    let title: String
    let message: String

    init(phase: SoloistSetupPhase) {
        switch PlaybackOnboardingScene(phase: phase) {
        case .entry:
            if case .failed = phase {
                title = "onboarding.attentionTitle"
                message = "onboarding.attentionDescription"
            } else {
                title = "onboarding.playbackTitle"
                message = "onboarding.playbackDescription"
            }
        case .pairing:
            title = "onboarding.pairingTitle"
            message = "onboarding.pairingDescription"
        case .ready:
            title = "onboarding.readyTitle"
            message = "onboarding.readyDescription"
        case .connecting:
            title = "onboarding.connectingTitle"
            message = "onboarding.connectingDescription"
        case .preparing:
            title = "onboarding.preparingTitle"
            message = ""
        }
    }
}

/// Waiting recovers automatically; only denied permission needs a Settings action.
struct SoloistPairingGuidance: View {
    let state: SoloistDiscovery.State
    var isConnectionUnavailable = false
    var isRecovering = false
    let openSettings: () -> Void
    let openSpotify: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            if state == .denied {
                StartupButton(key: "soloist.localNetworkSettings", identifier: "soloist.localNetworkSettings", action: openSettings)
                Text("soloist.discoveryDenied", bundle: SoloistResources.bundle)
                    .font(.callout).startupSupporting()
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("soloist.discoveryDenied")
            } else {
                if !isConnectionUnavailable {
                    StartupButton(key: "onboarding.openSpotify", identifier: "soloist.openSpotify", action: openSpotify)
                }
                HStack(spacing: 7) {
                    if isConnectionUnavailable && !isRecovering {
                        Image(systemName: "wifi.exclamationmark")
                    } else {
                        ProgressView().controlSize(.mini)
                    }
                    Text(state == .unavailable ? "soloist.discoveryUnavailable" :
                         isConnectionUnavailable ? (isRecovering ? "soloist.discoveryRecovering" : "soloist.connectionUnavailable") : "soloist.pairingHelp", bundle: SoloistResources.bundle)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier(state == .unavailable ? "soloist.discoveryUnavailable" :
                                                 isConnectionUnavailable ? (isRecovering ? "soloist.discoveryRecovering" : "soloist.connectionUnavailable") : "soloist.pairingHelp")
                }
                .font(.callout).startupStatus()
            }
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
        case .discovery: "soloist.error.discovery"
        case .rateLimited: "soloist.error.rateLimited"
        }
    }
}
