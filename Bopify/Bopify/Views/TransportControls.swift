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
    private var nextRepeat: RepeatMode {
        switch state.repeatMode { case .off: .context; case .context: .track; case .track: .off }
    }

    var body: some View {
        HStack(spacing: 16) {
            Button { model.setShuffle(!state.shuffleEnabled) } label: {
                modeSymbol("shuffle", active: state.shuffleEnabled)
            }
            .disabled(!canControl)
            .accessibilityLabel(Text("transport.shuffle"))
            .accessibilityValue(Text(state.shuffleEnabled ? "control.on" : "control.off"))
            .help(Text("transport.shuffle"))
            Button(action: model.previous) {
                Image(systemName: "backward.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 40, height: 40)
            }
            .disabled(!canControl || !state.canPrevious)
            .accessibilityLabel(Text("transport.previous"))
            .help(Text("transport.previous"))
            .keyboardShortcut(.leftArrow, modifiers: .command)

            Button(action: model.togglePlayPause) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 23, weight: .semibold))
                    .offset(x: isPlaying ? 0 : 2)
                    .frame(width: 48, height: 48)
                    .background(.primary.opacity(0.1), in: Circle())
            }
            .disabled(!canControl || state.phase == .loading || state.phase == .buffering)
            .accessibilityLabel(Text(isPlaying ? "transport.pause" : "transport.play"))
            .accessibilityValue(Text(isPlaying ? "transport.state.playing" : "transport.state.paused"))
            .help(Text(isPlaying ? "transport.pause" : "transport.play"))

            Button(action: model.next) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 40, height: 40)
            }
            .disabled(!canControl || !state.canNext)
            .accessibilityLabel(Text("transport.next"))
            .help(Text("transport.next"))
            .keyboardShortcut(.rightArrow, modifiers: .command)

            Button { model.setRepeat(nextRepeat) } label: {
                modeSymbol(state.repeatMode == .track ? "repeat.1" : "repeat", active: state.repeatMode != .off)
            }
            .disabled(!canControl)
            .accessibilityLabel(Text("transport.repeat"))
            .accessibilityValue(Text(state.repeatMode == .off ? "control.off" : state.repeatMode == .track ? "transport.repeat.track" : "transport.repeat.context"))
            .help(Text("transport.repeat"))
        }
        .buttonStyle(PlayerControlStyle())
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .modifier(PlayerGlass())
    }
    private func modeSymbol(_ name: String, active: Bool) -> some View {
        Image(systemName: name)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.white.opacity(active ? 1 : 0.48))
            .frame(width: 32, height: 40)
            .overlay(alignment: .bottom) { if active { Circle().fill(.white).frame(width: 3, height: 3).padding(.bottom, 2) } }
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
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.16), value: hovered)
            .onHover { hovered = $0 }
    }
}
