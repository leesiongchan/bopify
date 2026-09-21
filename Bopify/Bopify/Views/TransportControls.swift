import SwiftUI
import BopifyDomain
import BopifyPlayback

struct TransportControls: View {
    let state: PlaybackState
    let model: PlayerModel

    private var isPlaying: Bool { state.phase == .playing }

    var body: some View {
        HStack(spacing: 24) {
            Button(action: model.previous) {
                Image(systemName: "backward.fill")
            }
            .disabled(!state.canPrevious)
            .accessibilityLabel(Text("transport.previous"))

            Button(action: model.togglePlayPause) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.title)
            }
            // State is never carried by icon shape alone.
            .accessibilityLabel(Text(isPlaying ? "transport.pause" : "transport.play"))
            .accessibilityValue(Text(isPlaying ? "transport.state.playing" : "transport.state.paused"))

            Button(action: model.next) {
                Image(systemName: "forward.fill")
            }
            .disabled(!state.canNext)
            .accessibilityLabel(Text("transport.next"))
        }
        .buttonStyle(.plain)
    }
}
