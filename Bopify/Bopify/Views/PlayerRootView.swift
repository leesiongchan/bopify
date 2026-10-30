import SwiftUI
import BopifyLibrary
import BopifyDomain
import BopifyPlayback

struct PlayerRootView: View {
    let environment: AppEnvironment

    var body: some View {
        Group {
            if environment.isListening || environment.isLiveLyricsVisible, let player = environment.player {
                RecordPlayerView(player: player, artworkStore: environment.artworkStore,
                                   presentation: environment.presentation, windowController: environment.playerWindowController)
                    .id(ObjectIdentifier(player))
            } else {
                PlayerSurface {
                    VStack(spacing: 8) {
                        header
                        if let step = startupStep {
                            StartupView(step: step, isVisible: environment.presentation.isVisible) { startupContent(step) }
                        } else if let player = environment.player {
                            StartupPlayerContent(player: player)
                        }
                    }
                    .padding(16)
                    .modifier(ScrollablePlayerContent())
                    .background {
                        if let step = startupStep {
                            AuroraBackground(isAnimating: environment.presentation.isVisible, isDimmed: step.recordPose == .tucked)
                                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                        }
                    }
                }
            }
        }
        .environment(environment)
        .onChange(of: environment.hasLibraryAuthorizationFailure, initial: true) { _, failed in
            if failed { Task { await environment.requireLibrarySetup() } }
        }
        .onChange(of: environment.presentation.isVisible) { _, visible in
            if visible { environment.artworkStore.retryFailedLoads() }
            else { environment.player?.cancelVolumeEditing() }
        }
        .task(id: environment.player?.state.currentTrack?.uri) { await environment.refreshFavorite() }
        .onChange(of: environment.favorite.membershipRevision) { _, _ in
            Task { await environment.likedSongs.refresh() }
        }
    }

    private var header: some View {
        HStack {
            Label {
                Text("app.name")
            } icon: {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 18, height: 18)
            }
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            WindowDragRegion().frame(maxWidth: .infinity)
            if let step = startupStep {
                // Search and Favorite need a ready player, and reconnecting still counts as signed in.
                if let progress = step.progress { StartupStepPips(current: progress, total: 2) }
            } else {
                if environment.authState == .signedIn { SearchButton(environment: environment) }
                FavoriteButton()
                // Startup has no use for it: volume needs a ready player, and Quit and Sign out are in the status item's menu.
                Menu {
                    if let player = environment.player {
                        Slider(value: Binding(get: { player.displayVolume }, set: player.setVolume), in: 0...1,
                               onEditingChanged: { editing in
                                   if editing { player.beginVolumeEditing() } else { player.endVolumeEditing() }
                                   environment.presentation.sendAttention(.interaction(.volume, editing))
                               }) { Text("transport.volume") }
                            .disabled(!player.isEngineReady || !player.state.isActiveDevice)
                        Divider()
                    }
                    Button("menu.signOut") { Task { await environment.signOut() } }
                        .disabled(environment.authState != .signedIn && environment.authState != .needsLibraryAuthorization)
                    Divider()
                    Button("menu.quit") { Task { await environment.prepareForQuit(); NSApp.terminate(nil) } }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 28, height: 24).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel(Text("menu.options")).help(Text("menu.options"))
            }
        }
        .frame(height: 24)
    }

    private var startupStep: StartupStep? {
        switch environment.authState {
        case .signedOut: return .signIn(environment.isRemovingCredentials ? .removingCredentials : .idle)
        case .authenticating: return .signIn(.authenticating)
        case .refreshing: return .signIn(.restoring)
        case let .error(error): return .signIn(.error(error))
        case .needsLibraryAuthorization: return .library(environment.librarySetupStatus)
        case .signedIn:
            guard let player = environment.player else { return .signIn(.authenticating) }
            guard environment.connectionStatus != .ready || player.restorationUnavailable else { return nil }
            let status = connection(for: player)
            return .connection(messageKey: status.messageKey, isFailure: status.isFailure)
        }
    }

    private func connection(for player: PlayerModel) -> PlaybackConnectionStatusView {
        PlaybackConnectionStatusView(status: environment.connectionStatus, restorationUnavailable: player.restorationUnavailable, hasConnected: environment.hasPlaybackConnected, onRetry: environment.retryPlaybackConnection, onReconnect: { Task { await environment.reconnectSpotify() } }, isAuthorizing: environment.isAuthorizingPlayback, onCancel: environment.cancelPlaybackAuthorization)
    }

    /// Only an actual sign-in can be cancelled; once it succeeds, the player is just starting.
    private var signInCancel: (() -> Void)? {
        guard environment.authState == .authenticating else { return nil }
        return environment.cancelPlaybackAuthorization
    }

    @ViewBuilder private func startupContent(_ step: StartupStep) -> some View {
        switch step {
        case let .signIn(status):
            SignInView(status: status, onSignIn: requestSignIn,
                       onCancel: signInCancel,
                       onRetryCredentials: { Task { await environment.restoreOrPromptSignIn() } },
                       onRetryCleanup: { Task { await environment.signOut() } })
        case let .library(status):
            LibraryAuthorizationSetupView(status: status, environment: environment)
        case .connection:
            if let player = environment.player { StartupConnectionView(connection: connection(for: player)) }
        }
    }

    private func requestSignIn() { Task { await environment.signIn() } }
}

private struct StartupPlayerContent: View {
    let player: PlayerModel
    var body: some View {
        let content = PlayerContent(player.state)
        if content != .player {
            StartupContent(content: content, onPlayRequest: player.load).frame(maxHeight: .infinity)
        } else {
            VStack(spacing: 12) {
                if case let .error(error) = player.state.phase {
                    Label("player.error", systemImage: "exclamationmark.circle")
                    error.localizedText.foregroundStyle(.secondary)
                } else {
                    Text("player.inactiveDevice.title").foregroundStyle(.secondary)
                }
                if let notice = player.commandNotice { Text(notice).foregroundStyle(.secondary) }
            }
            .font(.callout).multilineTextAlignment(.center).frame(maxHeight: .infinity)
        }
    }
}

private struct ContextURILoadView: View {
    let onPlayRequest: (PlayRequest) -> Void
    @State private var contextURIText = ""

    var body: some View {
        VStack(spacing: 14) {
            Text("player.idle.title")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
            Text("player.idle.subtitle")
                .font(.callout)
                .foregroundStyle(.primary.opacity(0.7))
                .multilineTextAlignment(.center)
            HStack(spacing: 8) {
                TextField("player.idle.contextURI.placeholder", text: $contextURIText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(Text("player.idle.contextURI.label"))
                    .onSubmit(submit)
                Button("player.idle.contextURI.load", action: submit)
                    .disabled(SpotifyURI(contextURIText) == nil)
            }
            .controlSize(.large)
        }
    }

    private func submit() {
        guard let uri = SpotifyURI(contextURIText) else { return }
        onPlayRequest(PlayRequest(contextURI: uri))
    }
}

private struct StartupContent: View {
    let content: PlayerContent
    let onPlayRequest: (PlayRequest) -> Void

    var body: some View {
        switch content {
        case .chooseContext:
            ContextURILoadView(onPlayRequest: onPlayRequest)
        case let .remote(deviceName):
            placeholder { Text("player.remote.title \(deviceName)") }
        // Errors without metadata are rendered by StartupPlayerContent.
        case .loading, .player:
            placeholder { ProgressView { Text("player.loading") }.controlSize(.small) }
        }
    }

    private func placeholder(@ViewBuilder _ label: () -> some View) -> some View {
        VStack(spacing: 18) {
            ArtworkView(image: nil, diameter: 156)
            label()
                .font(.callout)
                .foregroundStyle(.primary.opacity(0.7))
        }
    }
}

#Preview("Signed out") {
    PlayerRootView(environment: AppEnvironment()).frame(width: 410, height: 560)
}

private struct ScrollablePlayerContent: ViewModifier {
    func body(content: Content) -> some View {
        GeometryReader { geometry in
            ScrollView {
                content.frame(height: max(560, geometry.size.height))
            }
            .scrollDisabled(geometry.size.height >= 560)
            .scrollIndicators(.never)
        }
    }
}

#Preview("Small display · sign in") {
    PlayerRootView(environment: AppEnvironment()).frame(width: 320, height: 480)
}

#if DEBUG
#Preview("Signed in · nothing playing") {
    PlayerRootView(environment: makePreviewEnvironment(.nothingPlaying)).frame(width: 410, height: 560)
}
#endif
