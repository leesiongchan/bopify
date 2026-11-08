import SwiftUI
import BopifyLibrary
import BopifyDomain
import BopifyPlayback

struct PlayerRootView: View {
    let environment: AppEnvironment
    @State private var startupSize: CGSize?
    @State private var startupRecordSide: RecordSide = .a
    @State private var lastMeasuredContent: String?
    @State private var waitsForContentSpace = false
    @State private var currentViewportHeight: CGFloat = 0

    var body: some View {
        GeometryReader { viewport in
            let transfer = environment.playerWindowController.onboardingHandoff
            let handingOff = environment.onboarding.phase == .handoff
            OnboardingHandoffScene(progress: handingOff ? environment.playerWindowController.onboardingProgress : 0) { visual in
                ZStack(alignment: .topLeading) {
                    if environment.isShowingPlayer, let player = environment.player {
                        RecordPlayerView(player: player, artworkStore: environment.artworkStore,
                                           presentation: environment.presentation, windowController: environment.playerWindowController,
                                           recordOpacity: handingOff ? visual.playerRecordOpacity : 1)
                            .opacity(handingOff ? visual.playerOpacity : 1)
                            .allowsHitTesting(!handingOff)
                            .accessibilityHidden(handingOff)
                            .id(ObjectIdentifier(player))
                            .transition(.opacity)
                    }
                    if !environment.isShowingPlayer || environment.onboarding.phase == .handoff {
                        StartupSurface(isAnimating: environment.presentation.isVisible, isDimmed: startupStep?.recordPose == .tucked,
                                       surfaceOpacity: handingOff ? visual.backgroundOpacity : 1) {
                            VStack(spacing: 8) {
                                header.opacity(handingOff ? visual.backgroundOpacity : 1)
                                if let step = startupStep {
                                    let identity = contentIdentity(for: step)
                                    StartupView(step: step, isVisible: environment.presentation.isVisible,
                                                onRecordFrameChanged: { if !handingOff { environment.onboardingRecordFrame = $0 } },
                                                recordScale: environment.startupWindow.isManaged ? environment.startupWindow.recordScale : nil,
                                                completionID: environment.onboarding.completionID,
                                                onCompletionSettled: { environment.onboarding.animationSettled(for: $0) },
                                                onRecordSideChanged: { startupRecordSide = $0 },
                                                pocketOpacity: handingOff ? visual.pocketOpacity : 1,
                                                recordOpacity: handingOff ? visual.sourceRecordOpacity : 1) {
                                        startupContent(step)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .onGeometryChange(for: StartupContentMeasurement.self) { geometry in
                                                StartupContentMeasurement(identity: identity, windowWidth: viewport.size.width, size: geometry.size)
                                            } action: { measurement in
                                                rememberContent(measurement)
                                                Task { @MainActor in
                                                    measureContent(measurement)
                                                }
                                            }
                                            .opacity(revealsContent ? (handingOff ? visual.backgroundOpacity : 1) : 0)
                                            .animation(revealsContent ? .easeIn(duration: 0.16) : nil, value: revealsContent)
                                            .allowsHitTesting(revealsContent)
                                            .accessibilityHidden(!revealsContent)
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
                        .opacity(handingOff ? visual.setupOpacity : 1)
                        .allowsHitTesting(!environment.isShowingPlayer)
                        .accessibilityHidden(environment.isShowingPlayer)
                        .zIndex(1)
                    }
                    if handingOff, let transfer {
                        OnboardingTransferRecord(geometry: transfer, progress: visual.progress, side: startupRecordSide,
                                                 onRecordFrameChanged: { environment.onboardingRecordFrame = $0 })
                            .opacity(visual.transferOpacity)
                            .zIndex(2)
                    }
                }
            }
            .frame(width: viewport.size.width, height: viewport.size.height, alignment: .topLeading)
            .onChange(of: viewport.size, initial: true) { _, size in
                currentViewportHeight = size.height
                if !environment.isShowingPlayer { startupSize = size }
                if size.height >= environment.startupWindow.height - 1 { waitsForContentSpace = false }
            }
            .onChange(of: environment.isShowingPlayer) { wasShowing, isShowing in
                if wasShowing && !isShowing {
                    startupSize = viewport.size
                    lastMeasuredContent = nil
                }
                if isShowing {
                    environment.startupWindow.cancelPendingResize()
                    waitsForContentSpace = false
                }
            }
            .onChange(of: environment.startupWindow.height) { _, height in
                if currentViewportHeight >= height - 1 { waitsForContentSpace = false }
            }
        }
        .environment(environment)
        .animation(environment.onboarding.phase == .handoff ? nil : .easeInOut(duration: 0.5),
                   value: environment.isShowingPlayer)
        .onChange(of: startupStep, initial: true) { _, step in
            if let step {
                if environment.startupWindow.isManaged, let width = startupSize?.width, (390...430).contains(width),
                   prepareStartupSizing(for: step, width: width, immediately: false) {
                    waitsForContentSpace = environment.startupWindow.height > currentViewportHeight + 1
                }
                environment.startupWindow.useStep(step)
            } else { environment.startupWindow.activateContent(nil) }
            if step == .completion || step == .library(.connected) {
                // Brief acknowledgements should not contract the window just before the next handoff.
                environment.startupWindow.cancelPendingResize()
                waitsForContentSpace = false
            }
        }
        .onAppear {
            environment.onboarding.setAnimationPresentationVisible(environment.presentation.isVisible)
        }
        .onDisappear { environment.onboarding.setAnimationPresentationVisible(false) }
        .onChange(of: environment.hasLibraryAuthorizationFailure, initial: true) { _, failed in
            if failed { Task { await environment.requireLibrarySetup() } }
        }
        .onChange(of: environment.presentation.isVisible) { _, visible in
            environment.onboarding.setAnimationPresentationVisible(visible)
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

    private var revealsContent: Bool {
        !environment.startupWindow.isManaged || !waitsForContentSpace
            || currentViewportHeight >= environment.startupWindow.height - 1
    }

    private func contentIdentity(for step: StartupStep) -> String {
        let scene: PlaybackOnboardingScene? = if case .playback = step {
            PlaybackOnboardingScene(phase: environment.soloist.phase)
        } else { nil }
        let library = if case .library = step {
            "\(environment.libraryClientID != nil):\(String(describing: environment.librarySetupError)):\(environment.libraryAuthorizationNotice ?? "")"
        } else { "" }
        return "\(step):\(String(describing: scene)):\(library)"
    }

    func startupMeasurementKey(for step: StartupStep, width: CGFloat) -> StartupWindowLayout.MeasurementKey {
        .init(identity: contentIdentity(for: step), width: width)
    }

    @discardableResult
    func prepareStartupSizing(for step: StartupStep, width: CGFloat, immediately: Bool) -> Bool {
        let layout = environment.startupWindow
        let key = startupMeasurementKey(for: step, width: width)
        layout.activateContent(key.identity)
        let content: AnyView
        switch step {
        case .signIn, .library(.idle), .library(.authorizing), .library(.refused):
            content = AnyView(startupContent(step).environment(environment))
        case .library(.connected), .playback, .connection, .completion:
            // Playback contains live discovery work; temporary acknowledgements retain their current allocation.
            return false
        }
        guard width.isFinite, width >= 100 else { return false }
        let height: CGFloat
        if let cached = layout.measuredHeight(for: key) { height = cached }
        else {
            // Existing editors/help keep their mounted state when width changes; their geometry remains authoritative.
            guard !layout.hasPreparedMeasurement(for: key.identity) else { return false }
            let formWidth = width - 32
            let measurer = NSHostingController(rootView: content.fixedSize(horizontal: false, vertical: true).frame(width: formWidth))
            height = measurer.sizeThatFits(in: CGSize(width: formWidth, height: .greatestFiniteMagnitude)).height
        }
        guard height.isFinite, height > 0 else { return false }
        layout.remember(contentHeight: height, for: key, prepared: true)
        layout.prepare(contentHeight: height, step: step, immediately: immediately)
        return true
    }

    private func rememberContent(_ measurement: StartupContentMeasurement) {
        guard let step = startupStep, contentIdentity(for: step) == measurement.identity else { return }
        environment.startupWindow.remember(contentHeight: measurement.size.height,
            for: .init(identity: measurement.identity, width: measurement.windowWidth))
    }

    private func measureContent(_ measurement: StartupContentMeasurement) {
        guard !environment.isPreparingForQuit, !environment.isShowingPlayer, let step = startupStep,
              step != .completion, step != .library(.connected),
              contentIdentity(for: step) == measurement.identity,
              abs(measurement.windowWidth - (startupSize?.width ?? measurement.windowWidth)) < 0.5,
              measurement.size.width >= 100, measurement.size.height.isFinite, measurement.size.height > 0 else { return }
        let changedScene = lastMeasuredContent != measurement.identity
        environment.startupWindow.measure(contentHeight: measurement.size.height)
        lastMeasuredContent = measurement.identity
        if changedScene {
            waitsForContentSpace = environment.startupWindow.isManaged
                && environment.startupWindow.height > currentViewportHeight + 1
        }
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

private nonisolated struct StartupContentMeasurement: Equatable, Sendable {
    let identity: String
    let windowWidth: CGFloat
    let size: CGSize
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
