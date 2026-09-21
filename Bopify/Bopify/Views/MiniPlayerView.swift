import SwiftUI
import BopifyDomain
import BopifyPlayback

/// The panel's whole content: switches on sign-in state, and within
/// `signedIn` on the engine's playback phase.
struct MiniPlayerView: View {
    let environment: AppEnvironment

    var body: some View {
        Group {
            switch environment.authState {
            case .signedOut, .needsReauthentication:
                SignedOutView(presentation: .idle, signIn: requestSignIn)
            case .authenticating, .refreshing:
                SignedOutView(presentation: .authenticating, signIn: requestSignIn)
            case let .error(error):
                SignedOutView(presentation: .error(error), signIn: requestSignIn)
            case .signedIn:
                if let player = environment.player {
                    PlayingView(player: player)
                } else {
                    // Momentary: signedIn is only set once the player exists.
                    SignedOutView(presentation: .authenticating, signIn: requestSignIn)
                }
            }
        }
        .frame(width: 320, height: 180)
        .padding()
    }

    private func requestSignIn() {
        Task { await environment.signIn() }
    }
}

/// Broken out of `MiniPlayerView` so `state` reads once per phase switch
/// rather than once per case.
private struct PlayingView: View {
    let player: PlayerModel

    var body: some View {
        let state = player.state
        VStack(spacing: 12) {
            switch state.phase {
            case .idle:
                if !state.isActiveDevice, let track = state.currentTrack {
                    inactiveDeviceView(track: track)
                } else {
                    idleView
                }
            case .loading:
                ProgressView { Text("player.loading") }
            case .buffering:
                ProgressView { Text("player.buffering") }
            case .playing, .paused:
                nowPlayingView(state: state)
            case .ended:
                Text("player.ended")
            case let .error(error):
                VStack(spacing: 4) {
                    Text("player.error")
                    Text(String(describing: error))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func nowPlayingView(state: PlaybackState) -> some View {
        HStack(spacing: 12) {
            ArtworkView(artwork: state.currentTrack?.artwork)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.currentTrack?.title ?? String(localized: "player.unknownTrack"))
                    .font(.headline)
                    .lineLimit(1)
                Text(artistNames(state.currentTrack))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        TransportControls(state: state, model: player)
    }

    @ViewBuilder
    private func inactiveDeviceView(track: Track) -> some View {
        ArtworkView(artwork: track.artwork)
        Text("player.inactiveDevice.title")
            .font(.headline)
        Text(track.title)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private var idleView: some View {
        ContextURILoadView(load: player.load)
    }

    private func artistNames(_ track: Track?) -> String {
        guard let track, !track.artists.isEmpty else { return "" }
        return track.artists.map(\.name).joined(separator: ", ")
    }
}

/// Q5 (does a token-authenticated device appear for Connect handoff?) was
/// never resolved, so this control is offered unconditionally alongside
/// waiting for handoff: it costs nothing when handoff works, and covers the
/// case where it does not.
private struct ContextURILoadView: View {
    let load: (PlayRequest) -> Void
    @State private var contextURIText = ""

    var body: some View {
        Text("player.idle.title")
            .font(.headline)
        Text("player.idle.subtitle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        HStack {
            TextField("player.idle.contextURI.placeholder", text: $contextURIText)
                .textFieldStyle(.roundedBorder)
            Button("player.idle.contextURI.load", action: submit)
                .disabled(SpotifyURI(contextURIText) == nil)
        }
    }

    private func submit() {
        guard let uri = SpotifyURI(contextURIText) else { return }
        load(PlayRequest(contextURI: uri))
    }
}
