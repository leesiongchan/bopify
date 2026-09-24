import SwiftUI
import BopifyDomain
import BopifyPlayback

struct MiniPlayerView: View {
    let environment: AppEnvironment

    var body: some View {
        AsyncImage(url: environment.player?.state.currentTrack?.artwork?.url) { phase in
            PlayerSurface(image: phase.image) {
                VStack(spacing: 12) {
                    HStack {
                        Label("app.name", systemImage: "waveform")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary.opacity(0.7))
                        Spacer()
                        Menu {
                            Button("menu.signOut") { Task { await environment.signOut() } }
                                .disabled(environment.authState != .signedIn)
                            Divider()
                            Button("menu.quit") {
                                Task {
                                    await environment.prepareForQuit()
                                    NSApp.terminate(nil)
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .frame(width: 28, height: 24)
                                .contentShape(Rectangle())
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .accessibilityLabel(Text("menu.options"))
                        .help(Text("menu.options"))
                    }
                    .frame(height: 24)

                    switch environment.authState {
                    case .signedOut, .needsReauthentication:
                        SignedOutView(presentation: .idle, signIn: requestSignIn)
                    case .authenticating, .refreshing:
                        SignedOutView(presentation: .authenticating, signIn: requestSignIn)
                    case let .error(error):
                        SignedOutView(presentation: .error(error), signIn: requestSignIn)
                    case .signedIn:
                        if let player = environment.player {
                            PlayingView(player: player, image: phase.image, state: player.state,
                                        position: player.displayPositionMs)
                        } else {
                            SignedOutView(presentation: .authenticating, signIn: requestSignIn)
                        }
                    }
                }
            }
        }
    }

    private func requestSignIn() {
        Task { await environment.signIn() }
    }
}

struct PlayingView: View {
    let player: PlayerModel
    let image: Image?
    let state: PlaybackState
    let position: (Date) -> Int64

    var body: some View {
        VStack(spacing: 12) {
            ArtworkView(image: image)
            if state.phase == .idle && state.currentTrack == nil {
                ContextURILoadView(load: player.load)
                    .frame(maxHeight: .infinity)
            } else {
                VStack(spacing: 4) {
                    Text(state.currentTrack?.title ?? String(localized: "player.unknownTrack"))
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
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

                TransportControls(state: state, model: player)
                status(state: state)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
            }
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func status(state: PlaybackState) -> some View {
        switch state.phase {
        case .playing, .paused:
            TimelineView(.animation(minimumInterval: 1, paused: state.phase != .playing)) { context in
                let position = position(context.date)
                VStack(spacing: 7) {
                    ProgressView(value: Double(position), total: Double(max(1, state.durationMs)))
                        .tint(.primary.opacity(0.65))
                        .accessibilityLabel(Text("player.progress"))
                        .accessibilityValue(Text(String(format: String(localized: "player.progress.value"),
                                                        time(position), time(state.durationMs))))
                    HStack {
                        Text(time(position))
                        Spacer()
                        Text(state.phase == .paused ? "transport.state.paused" : "player.nowPlaying")
                        Spacer()
                        Text(time(state.durationMs))
                    }
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.7))
                    .accessibilityHidden(true)
                }
            }
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

    private func time(_ milliseconds: Int64) -> String {
        let seconds = max(0, milliseconds / 1000)
        return String(format: "%lld:%02lld", seconds / 60, seconds % 60)
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
    MiniPlayerView(environment: AppEnvironment())
}
