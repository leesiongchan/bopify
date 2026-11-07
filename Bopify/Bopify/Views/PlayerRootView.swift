import SwiftUI
import BopifyLibrary
import BopifyDomain
import BopifyPlayback

struct PlayerRootView: View {
    let environment: AppEnvironment

    var body: some View {
        Group {
            if environment.isShowingPlayer, let player = environment.player {
                RecordPlayerView(player: player, artworkStore: environment.artworkStore,
                                   presentation: environment.presentation, windowController: environment.playerWindowController)
                    .id(ObjectIdentifier(player))
            } else {
                PlayerSurface {
                    VStack(spacing: 8) {
                        header
                        if let step = startupStep {
                            StartupView(step: step, isVisible: environment.presentation.isVisible) { startupContent(step) }
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
                if let progress = step.progress { StartupStepPips(current: progress, total: 3) }
                if environment.authState == .signedIn, environment.requestedOnboardingSection != nil,
                   environment.soloist.hasUsablePlayback {
                    Button(SoloistResources.string("onboarding.done"), action: environment.closeOnboarding)
                        .buttonStyle(.plain).font(.caption)
                }
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
                    if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                        Divider()
                        Text(verbatim: "Bopify \(version)")
                    }
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
        if let step = environment.onboardingStep { return step }
        guard let player = environment.player,
              environment.connectionStatus != .ready || player.restorationUnavailable else { return nil }
        let status = connection(for: player)
        return .connection(messageKey: status.messageKey, isFailure: status.isFailure)
    }

    private func connection(for player: PlayerModel) -> PlaybackConnectionStatusView {
        PlaybackConnectionStatusView(status: environment.connectionStatus, restorationUnavailable: player.restorationUnavailable, hasConnected: environment.hasPlaybackConnected, onRetry: environment.retryPlaybackConnection, onReconnect: { Task { await environment.reconnectSpotify() } }, offersRetry: environment.offersPlaybackRetry, isAuthorizing: environment.isAuthorizingPlayback, onCancel: environment.cancelPlaybackAuthorization)
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
        case .playback:
            PlaybackOnboardingView(environment: environment)
        case .connection:
            if let player = environment.player { StartupConnectionView(connection: connection(for: player)) }
        }
    }

    private func requestSignIn() { Task { await environment.signIn() } }
}

#Preview("Signed out") {
    PlayerRootView(environment: AppEnvironment()).frame(width: 410, height: 560)
}

private struct ScrollablePlayerContent: ViewModifier {
    func body(content: Content) -> some View {
        StartupScrollView(content: content)
    }
}

/// A native scroll area preserves the hosted form's accessibility nodes on macOS.
private struct StartupScrollView<Content: View>: NSViewRepresentable {
    let content: Content

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.horizontalScrollElasticity = .none
        let clip = StartupClipView()
        clip.drawsBackground = false
        scroll.contentView = clip
        let host = NSHostingView(rootView: AnyView(content.environment(\.self, context.environment)))
        host.sizingOptions = [.intrinsicContentSize]
        host.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = host
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            host.topAnchor.constraint(equalTo: clip.topAnchor),
            host.widthAnchor.constraint(equalTo: clip.widthAnchor),
            host.heightAnchor.constraint(greaterThanOrEqualTo: clip.heightAnchor),
        ])
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let host = scroll.documentView as? NSHostingView<AnyView> else { return }
        host.rootView = AnyView(content.environment(\.self, context.environment))
    }
}

private final class StartupClipView: NSClipView {
    override var isFlipped: Bool { true }
}

#Preview("Small display · sign in") {
    PlayerRootView(environment: AppEnvironment()).frame(width: 320, height: 480)
}

#if DEBUG
#Preview("Signed in · nothing playing") {
    PlayerRootView(environment: makePreviewEnvironment(.nothingPlaying)).frame(width: 410, height: 560)
}
#endif
