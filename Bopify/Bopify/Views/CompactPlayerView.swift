import SwiftUI
import BopifyDomain
import BopifyPlayback

struct CompactPlayerView: View {
    let player: PlayerModel
    let state: PlaybackState
    let store: ArtworkStore
    let presentation: PlayerPresentation
    let artworkNamespace: Namespace.ID

    private var image: Image? { (state.currentTrack?.artwork?.url).flatMap { store.images[$0] }.map { Image(nsImage: $0) } }

    var body: some View {
        HStack(spacing: 10) {
            Button { presentation.setMode(.expanded) } label: {
                ArtworkView(image: image, diameter: 48)
                    .modifier(CurrentArtworkMatch(namespace: artworkNamespace, active: true))
            }
            .accessibilityLabel(Text("player.expand"))
            .contextMenu { Button("queue.title") { presentation.setMode(.queue) } }
            VStack(alignment: .leading, spacing: 4) {
                Text(state.currentTrack?.title ?? String(localized: "player.unknownTrack"))
                    .font(.system(size: 13)).lineLimit(1)
                Text(state.currentTrack?.artists.map(\.name).joined(separator: ", ") ?? "")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .help(state.currentTrack?.title ?? "")
            Button(action: player.togglePlayPause) {
                Image(systemName: state.phase == .playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 17)).frame(width: 32, height: 40)
            }
            .disabled(!state.isActiveDevice || state.phase == .loading || state.phase == .buffering)
            .accessibilityLabel(Text(state.phase == .playing ? "transport.pause" : "transport.play"))
            Button(action: player.next) {
                Image(systemName: "forward.fill").font(.system(size: 15)).frame(width: 28, height: 40)
            }
            .disabled(!state.isActiveDevice || !state.canNext)
            .accessibilityLabel(Text("transport.next"))
            Button { presentation.setMode(.expanded) } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 11)).frame(width: 24, height: 40)
            }
            .accessibilityLabel(Text("player.expand"))
        }
        .buttonStyle(PlayerControlStyle())
        .padding(12)
        .modifier(PlayerGlass())
        .contextMenu {
            Button("queue.title") { presentation.setMode(.queue) }
            Toggle("window.keepOnTop", isOn: Binding(get: { presentation.keepOnTop }, set: { presentation.keepOnTop = $0 }))
        }
    }
}

struct CurrentArtworkMatch: ViewModifier {
    let namespace: Namespace.ID
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        if active && !reduceMotion {
            content.matchedGeometryEffect(id: "current-artwork", in: namespace)
        } else { content }
    }
}
