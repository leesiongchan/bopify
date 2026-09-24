import SwiftUI
import BopifyDomain
import BopifyPlayback

struct TransportControls: View {
    let state: PlaybackState
    let model: PlayerModel

    private var isPlaying: Bool { state.phase == .playing }
    private var canControl: Bool {
        state.isActiveDevice && (state.phase == .playing || state.phase == .paused)
    }

    var body: some View {
        HStack(spacing: 22) {
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
            .disabled(!canControl)
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
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .modifier(PlayerGlass())
    }
}
