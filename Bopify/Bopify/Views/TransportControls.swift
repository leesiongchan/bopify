import SwiftUI
import BopifyDomain
import BopifyPlayback

struct TransportControls: View {
    let state: PlaybackState
    let model: PlayerModel

    private var isPlaying: Bool { state.phase == .playing }
    private var canControl: Bool {
        state.isActiveDevice && state.currentTrack != nil
    }
    var body: some View {
        HStack(spacing: 8) {
            Button(action: model.previous) {
                Image(systemName: "backward.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 40, height: 40)
            }
            .disabled(!canControl || !state.canPrevious)
            .accessibilityLabel(Text("transport.previous"))
            .help(Text("transport.previous"))

            Button(action: model.togglePlayPause) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 23, weight: .semibold))
                    .offset(x: isPlaying ? 0 : 2)
                    .frame(width: 48, height: 48)
                    .background(.primary.opacity(0.1), in: Circle())
            }
            .disabled(!canControl || state.phase == .loading || state.phase == .buffering)
            .accessibilityLabel(Text(isPlaying ? "transport.pause" : "transport.play"))
            .accessibilityValue(state.localizedStatusText)
            .help(Text(isPlaying ? "transport.pause" : "transport.play"))

            Button(action: model.next) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 40, height: 40)
            }
            .disabled(!canControl || !state.canNext)
            .accessibilityLabel(Text("transport.next"))
            .help(Text("transport.next"))
        }
        .buttonStyle(PlayerControlStyle())
    }
}

struct PlayerControlStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PlayerControlBody(configuration: configuration)
    }
}

private struct PlayerControlBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovered = false
    var body: some View {
        configuration.label
            .contentShape(Capsule())
            .background(.white.opacity(hovered ? 0.08 : 0), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.14), value: hovered)
            .onHover { hovered = $0 }
    }
}
