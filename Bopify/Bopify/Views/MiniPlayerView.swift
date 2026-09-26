import SwiftUI
import BopifyDomain
import BopifyPlayback

struct MiniPlayerView: View {
    let environment: AppEnvironment
    @Namespace private var artworkNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let url = environment.player?.state.currentTrack?.artwork?.url
        let image = url.flatMap { environment.artworkStore.images[$0] }.map { Image(nsImage: $0) }
        let mode = environment.playerMode
        PlayerSurface(palette: url.flatMap { environment.artworkStore.palettes[$0] } ?? .neutral) {
            if mode == .compact, let player = environment.player, player.state.currentTrack != nil {
                CompactPlayerView(player: player, state: player.state, store: environment.artworkStore,
                                  presentation: environment.presentation, artworkNamespace: artworkNamespace)
                    .padding(8)
            } else {
                VStack(spacing: 8) {
                    header
                    switch environment.authState {
                    case .signedOut, .needsReauthentication:
                        SignedOutView(presentation: .idle, signIn: requestSignIn)
                    case .authenticating, .refreshing:
                        SignedOutView(presentation: .authenticating, signIn: requestSignIn)
                    case let .error(error):
                        SignedOutView(presentation: .error(error), signIn: requestSignIn)
                    case .signedIn:
                        if let player = environment.player {
                            if mode == .queue {
                                QueueView(player: player, state: player.state, store: environment.artworkStore,
                                          presentation: environment.presentation, artworkNamespace: artworkNamespace)
                            } else {
                                PlayingView(player: player, image: image, state: player.state,
                                            position: player.displayPositionMs, store: environment.artworkStore,
                                            presentation: environment.presentation, artworkNamespace: artworkNamespace,
                                            isVisible: environment.presentation.isVisible)
                            }
                        } else {
                            SignedOutView(presentation: .authenticating, signIn: requestSignIn)
                        }
                    }
                }
                .padding(16)
                .modifier(ScrollablePlayerContent(mode: mode))
            }
        }
        .modifier(SharedCurrentArtwork(image: image, namespace: artworkNamespace))
        .animation(.spring(duration: reduceMotion ? 0.16 : 0.55, bounce: reduceMotion ? 0 : 0.04), value: mode)
        .environment(\.favoriteEnvironment, environment)
        .task(id: environment.player?.state.currentTrack?.uri) { await environment.refreshFavorite() }
        .task(id: url) { if let url { await environment.artworkStore.load(url) } }
    }

    private var header: some View {
        HStack {
            if environment.playerMode == .queue {
                Button { environment.presentation.setMode(.expanded) } label: {
                    Label("queue.title", systemImage: "chevron.left")
                        .font(.system(size: 15, weight: .medium))
                }
                .buttonStyle(.plain)
            } else {
                Label("app.name", systemImage: "waveform")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            }
            WindowDragRegion().frame(maxWidth: .infinity)
            FavoriteButton()
            Menu {
                if let player = environment.player {
                    Slider(value: Binding(get: { player.state.volume }, set: player.setVolume), in: 0...1) { Text("transport.volume") }
                        .disabled(!player.state.isActiveDevice)
                    Divider()
                }
                Toggle("window.keepOnTop", isOn: Binding(get: { environment.presentation.keepOnTop }, set: { environment.presentation.keepOnTop = $0 }))
                Button("menu.signOut") { Task { await environment.signOut() } }.disabled(environment.authState != .signedIn)
                Divider()
                Button("menu.quit") { Task { await environment.prepareForQuit(); NSApp.terminate(nil) } }
            } label: {
                Image(systemName: "ellipsis").frame(width: 28, height: 24).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel(Text("menu.options")).help(Text("menu.options"))
        }
        .frame(height: 24)
    }

    private func requestSignIn() { Task { await environment.signIn() } }
}

struct PlayingView: View {
    let player: PlayerModel
    let image: Image?
    let state: PlaybackState
    let position: (Date) -> Int64
    let store: ArtworkStore
    let presentation: PlayerPresentation
    let artworkNamespace: Namespace.ID
    var isVisible = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 8) {
            if state.phase == .idle && state.currentTrack == nil {
                ContextURILoadView(load: player.load)
                    .frame(maxHeight: .infinity)
            } else {
                VStack(spacing: 4) {
                    Text(state.currentTrack?.title ?? String(localized: "player.unknownTrack"))
                        .font(.system(size: 20, weight: .regular))
                        .lineLimit(1)
                        .help(state.currentTrack?.title ?? "")
                    Text(state.currentTrack?.artists.map(\.name).joined(separator: ", ") ?? "")
                        .font(.system(size: 13))
                        .foregroundStyle(.primary.opacity(0.7))
                        .lineLimit(1)
                        .help(state.currentTrack?.artists.map(\.name).joined(separator: ", ") ?? "")
                }
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .accessibilityElement(children: .combine)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: reduceMotion ? 0.16 : 0.72), value: state.currentTrack)

                TimelineView(PlaybackClockSchedule(running: state.phase == .playing && isVisible, reducedMotion: reduceMotion)) { context in
                    ArtworkCarouselView(queue: state.queue, currentTrack: state.currentTrack, image: image, store: store, artworkNamespace: artworkNamespace)
                        .overlay {
                            GeometryReader { geometry in
                                let diameter = min(310, geometry.size.width - 68)
                                RadialProgressView(positionMs: position(context.date), durationMs: state.durationMs,
                                                   canSeek: state.canSeek && state.isActiveDevice, seek: player.seek(to:))
                                    .frame(width: diameter, height: diameter)
                                    .position(x: geometry.size.width / 2, y: 165)
                                    .id(state.queue?.current?.id ?? state.currentTrack?.uri.rawValue)
                            }
                        }
                }
                TransportControls(state: state, model: player)
                HStack {
                    Button { presentation.setMode(.queue) } label: { Image(systemName: "music.note.list").frame(width: 32, height: 28) }
                        .accessibilityLabel(Text("queue.title")).help(Text("queue.title"))
                    Spacer(minLength: 4)
                    status(state: state).frame(maxWidth: .infinity)
                    Spacer(minLength: 4)
                    Button { presentation.setMode(.compact) } label: { Image(systemName: "arrow.down.right.and.arrow.up.left").frame(width: 32, height: 28) }
                        .accessibilityLabel(Text("player.collapse")).help(Text("player.collapse"))
                }
                .buttonStyle(PlayerControlStyle())
                .foregroundStyle(.secondary)
                .frame(height: 28)
            }
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func status(state: PlaybackState) -> some View {
        switch state.phase {
        case .playing, .paused:
            Text(player.commandNotice ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case .loading, .buffering:
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini)
                Text(state.phase == .loading ? "player.loading" : "player.buffering")
            }
            .font(.caption)
            .foregroundStyle(.primary.opacity(0.7))
        case .idle:
            Text("player.inactiveDevice.title")
                .font(.caption)
                .foregroundStyle(.primary.opacity(0.7))
        case .ended:
            Text("player.ended")
                .font(.caption)
                .foregroundStyle(.primary.opacity(0.7))
        case let .error(error):
            VStack(spacing: 3) {
                Label("player.error", systemImage: "exclamationmark.circle")
                    .fontWeight(.medium)
                error.localizedText
                    .foregroundStyle(.primary.opacity(0.7))
            }
            .font(.caption)
            .multilineTextAlignment(.center)
        }
    }


}

private struct ContextURILoadView: View {
    let load: (PlayRequest) -> Void
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
        load(PlayRequest(contextURI: uri))
    }
}

#Preview("Signed out") {
    MiniPlayerView(environment: AppEnvironment()).frame(width: 410, height: 560)
}

private struct ScrollablePlayerContent: ViewModifier {
    let mode: PlayerMode
    func body(content: Content) -> some View {
        if mode == .queue {
            content
        } else {
            GeometryReader { geometry in
                ScrollView {
                    content.frame(height: max(560, geometry.size.height))
                }
                .scrollDisabled(geometry.size.height >= 560)
                .scrollIndicators(.hidden)
            }
        }
    }
}

#Preview("Small display · sign in") {
    MiniPlayerView(environment: AppEnvironment()).frame(width: 320, height: 480)
}
