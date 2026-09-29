import SwiftUI
import BopifyDomain
import BopifyPlayback

struct TransportControls: View {
    let player: PlayerModel

    private var state: PlaybackState { player.state }
    private var isPlaying: Bool { state.phase == .playing }
    private var canControl: Bool {
        state.isActiveDevice && state.currentTrack != nil
    }
    var body: some View {
        HStack(spacing: 8) {
            Button(action: player.previous) {
                Image(systemName: "backward.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 40, height: 40)
            }
            .disabled(!canControl || !state.canPrevious)
            .accessibilityLabel(Text("transport.previous"))
            .help(Text("transport.previous"))

            Button(action: player.togglePlayPause) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 23, weight: .semibold))
                    .offset(x: isPlaying ? 0 : 2)
                    .frame(width: 48, height: 48)
                    .background(.primary.opacity(0.1), in: Circle())
            }
            .disabled(!(canControl || player.canPlayHere) || state.phase == .loading || state.phase == .buffering)
            .accessibilityLabel(Text(isPlaying ? "transport.pause" : "transport.play"))
            .accessibilityValue(state.localizedStatusText)
            .help(Text(isPlaying ? "transport.pause" : "transport.play"))

            Button(action: player.next) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 40, height: 40)
            }
            .disabled(!canControl || !state.canNext)
            .accessibilityLabel(Text("transport.next"))
            .help(Text("transport.next"))
        }
        .buttonStyle(.playerControl)
    }
}
