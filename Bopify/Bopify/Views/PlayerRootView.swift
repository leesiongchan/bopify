import SwiftUI
import BopifyLibrary
import BopifyDomain
import BopifyPlayback

struct PlayerRootView: View {
    let environment: AppEnvironment
    @State private var startupSize: CGSize?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { viewport in
            ZStack(alignment: .topLeading) {
                if environment.isShowingPlayer, let player = environment.player {
                    RecordPlayerView(player: player, artworkStore: environment.artworkStore,
                                       presentation: environment.presentation, windowController: environment.playerWindowController)
                        .id(ObjectIdentifier(player))
                        .transition(.opacity)
                }
                if !environment.isShowingPlayer || environment.onboarding.phase == .handoff {
                    StartupSurface(isAnimating: environment.presentation.isVisible, isDimmed: startupStep?.recordPose == .tucked) {
                        VStack(spacing: 8) {
                            header
                            if let step = startupStep {
                                StartupView(step: step, isVisible: environment.presentation.isVisible,
                                            onRecordFrameChanged: { environment.onboardingRecordFrame = $0 }) {
                                    startupContent(step)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                                        .modifier(NativeStartupContent())
                                }
                            }
                        }
                        .padding(16)
                    }
                    .frame(width: environment.onboarding.phase == .handoff ? startupSize?.width : viewport.size.width,
                           height: environment.onboarding.phase == .handoff ? startupSize?.height : viewport.size.height)
                    .offset(x: handoffOffset.x, y: handoffOffset.y)
                    .animation(nil, value: handoffOffset)
                    .opacity(environment.isShowingPlayer ? 0 : 1)
                    .allowsHitTesting(!environment.isShowingPlayer)
                    .accessibilityHidden(environment.isShowingPlayer)
                    .zIndex(1)
                }
            }
            .frame(width: viewport.size.width, height: viewport.size.height, alignment: .topLeading)
            .onChange(of: viewport.size, initial: true) { _, size in
                if !environment.isShowingPlayer { startupSize = size }
            }
            .onChange(of: environment.isShowingPlayer) { wasShowing, isShowing in
                if wasShowing && !isShowing { startupSize = viewport.size }
            }
        }
        .environment(environment)
        .animation(.easeInOut(duration: reduceMotion ? 0.15 : 0.5), value: environment.isShowingPlayer)
        .onChange(of: environment.soloist.hasUsablePlayback, initial: true) { _, _ in
            environment.updateOnboardingReadiness(reduceMotion: reduceMotion)
        }
        .onChange(of: environment.authState) { _, state in
            if state == .signedIn { environment.updateOnboardingReadiness(reduceMotion: reduceMotion) }
        }
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
                Text("app.name", bundle: SoloistResources.bundle)
            } icon: {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 18, height: 18)
            }
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            WindowDragRegion().frame(maxWidth: .infinity)
            if let step = startupStep {
                // Search and Favorite need a ready player, and reconnecting still counts as signed in.
                if let progress = step.progress { StartupStepIndicator(current: progress, total: 3) }
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
        if environment.onboarding.phase == .handoff { return .completion }
        if let step = environment.onboardingStep { return step }
        guard let player = environment.player,
              environment.connectionStatus != .ready || player.restorationUnavailable else { return nil }
        let status = connection(for: player)
        return .connection(messageKey: status.messageKey, isFailure: status.isFailure)
    }

    private var handoffOffset: CGPoint {
        environment.onboarding.phase == .handoff ? environment.playerWindowController.onboardingContentOffset : .zero
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
        case .completion:
            StartupHeading(title: Text("onboarding.readyTitle", bundle: SoloistResources.bundle),
                           message: Text("onboarding.readyDescription", bundle: SoloistResources.bundle), isCompact: true)
        case .connection:
            if let player = environment.player { StartupConnectionView(connection: connection(for: player)) }
        }
    }

    private func requestSignIn() { Task { await environment.signIn() } }
}

#Preview("Signed out") {
    PlayerRootView(environment: AppEnvironment()).frame(width: 410, height: 560)
}

private struct NativeStartupContent: ViewModifier {
    func body(content: Content) -> some View {
        StartupFormHost(content: content)
    }
}

/// Keep native editor accessibility without introducing a scrolling document or its saved offset.
private struct StartupFormHost<Content: View>: NSViewRepresentable {
    let content: Content

    func makeNSView(context: Context) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: AnyView(content.environment(\.self, context.environment)))
        host.sizingOptions = []
        return host
    }

    func updateNSView(_ host: NSHostingView<AnyView>, context: Context) {
        withTransaction(context.transaction) {
            host.rootView = AnyView(content.environment(\.self, context.environment))
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
