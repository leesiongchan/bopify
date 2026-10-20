import SwiftUI
import BopifyDomain
import BopifyPlayback

struct TransportControls: View {
    let player: PlayerModel
    @State private var previousTaps = 0
    @State private var nextTaps = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var state: PlaybackState { player.state }
    private var isPlaying: Bool { state.phase == .playing }
    private var canControl: Bool {
        player.isEngineReady && state.isActiveDevice && state.currentTrack != nil
    }
    var body: some View {
        HStack(spacing: 4) {
            Button { player.setShuffle(!state.shuffleEnabled) } label: {
                Image(systemName: "shuffle").frame(width: 28, height: 28)
                    .symbolEffect(.bounce, value: reduceMotion ? false : state.shuffleEnabled)
            }.buttonStyle(.playerToggle(isOn: state.shuffleEnabled, dimsWhenOff: true))
                .accessibilityLabel(Text("transport.shuffle"))
                .accessibilityValue(Text(state.shuffleEnabled ? "control.on" : "control.off"))
                .help(Text("transport.shuffle"))
                .disabled(!player.isEngineReady || !state.isActiveDevice)
            Button {
                if !reduceMotion { previousTaps += 1 }
                player.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .symbolEffect(.bounce.down, value: previousTaps)
                    .frame(width: 40, height: 40)
            }
            .disabled(!canControl || !state.canPrevious)
            .accessibilityLabel(Text("transport.previous"))
            .help(Text("transport.previous"))

            Button(action: player.togglePlayPause) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 23, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .offset(x: isPlaying ? 0 : 2)
                    .frame(width: 48, height: 48)
                    .background(.primary.opacity(0.1), in: Circle())
            }
            .disabled(!(canControl || player.canPlayHere) || state.phase == .loading || state.phase == .buffering)
            .accessibilityLabel(Text(isPlaying ? "transport.pause" : "transport.play"))
            .accessibilityValue(state.localizedStatusText)
            .help(Text(isPlaying ? "transport.pause" : "transport.play"))

            Button {
                if !reduceMotion { nextTaps += 1 }
                player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .symbolEffect(.bounce.down, value: nextTaps)
                    .frame(width: 40, height: 40)
            }
            .disabled(!canControl || !state.canNext)
            .accessibilityLabel(Text("transport.next"))
            .help(Text("transport.next"))

            Button {
                player.setRepeat(state.repeatMode == .off ? .context : state.repeatMode == .context ? .track : .off)
            } label: {
                Image(systemName: state.repeatMode == .track ? "repeat.1" : "repeat").frame(width: 28, height: 28)
                    .contentTransition(.symbolEffect(.replace))
            }.buttonStyle(.playerToggle(isOn: state.repeatMode != .off, dimsWhenOff: true))
                .accessibilityLabel(Text("transport.repeat"))
                .accessibilityValue(Text(state.repeatMode == .off ? "control.off" : state.repeatMode == .track ? "transport.repeat.track" : "transport.repeat.context"))
                .help(Text("transport.repeat"))
                .disabled(!player.isEngineReady || !state.isActiveDevice)
        }
        .buttonStyle(.playerControl)
    }
}

#if DEBUG
#Preview("Transport") {
    TransportControls(player: makePreviewEnvironment().player!).padding().frame(width: 260)
}
#endif
