import SwiftUI
import BopifyLibrary
import BopifyDomain
import BopifyPlayback

struct PlayerRootView: View {
    let environment: AppEnvironment

    var body: some View {
        Group {
            if environment.isListening, let player = environment.player {
                MonolithPlayerView(player: player, artworkStore: environment.artworkStore,
                                   presentation: environment.presentation, windowController: environment.monolithWindowController)
                    .id(ObjectIdentifier(player))
            } else {
                PlayerSurface {
                    VStack(spacing: 8) {
                        header
                        switch environment.authState {
                        case .signedOut, .needsReauthentication:
                            SignInView(status: .idle, onSignIn: requestSignIn)
                        case .authenticating, .refreshing:
                            SignInView(status: .authenticating, onSignIn: requestSignIn)
                        case let .error(error):
                            SignInView(status: .error(error), onSignIn: requestSignIn)
                        case .signedIn:
                            if let player = environment.player {
                                StartupPlayerContent(player: player)
                            } else {
                                SignInView(status: .authenticating, onSignIn: requestSignIn)
                            }
                        }
                    }
                    .padding(16)
                    .modifier(ScrollablePlayerContent(mode: .expanded))
                }
            }
        }
        .environment(environment)
        .onChange(of: environment.presentation.isVisible) { _, visible in
            if !visible { environment.player?.cancelVolumeEditing() }
        }
        .task(id: environment.player?.state.currentTrack?.uri) { await environment.refreshFavorite() }
        .onChange(of: environment.favorite.membershipRevision) { _, _ in
            Task { await environment.likedSongs.refresh() }
        }
    }

    private var header: some View {
        HStack {
            Label("app.name", systemImage: "waveform")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            WindowDragRegion().frame(maxWidth: .infinity)
            FavoriteButton()
            Menu {
                if let player = environment.player {
                    Slider(value: Binding(get: { player.displayVolume }, set: player.setVolume), in: 0...1,
                           onEditingChanged: { editing in
                               if editing { player.beginVolumeEditing() } else { player.endVolumeEditing() }
                               environment.presentation.sendAttention(.interaction(.volume, editing))
                           }) { Text("transport.volume") }
                        .disabled(!player.state.isActiveDevice)
                    Divider()
                }
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
    PlayerRootView(environment: AppEnvironment()).frame(width: 320, height: 480)
}
