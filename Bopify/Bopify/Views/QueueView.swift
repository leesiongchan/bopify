import SwiftUI
import BopifyDomain
import BopifyPlayback

struct QueueView: View {
    let player: PlayerModel
    private var state: PlaybackState { player.state }
    let artworkStore: ArtworkStore
    let onSelect: (QueueEntry) -> Void

    var body: some View {
        GeometryReader { geometry in
        ScrollView {
            LazyVStack(spacing: 1) {
                if let queue = state.queue {
                    if let current = queue.current { row(for: current, isCurrent: true) }
                    ForEach(queue.next) { entry in row(for: entry, isCurrent: false) }
                    if queue.next.isEmpty {
                        Text("queue.empty").font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 40)
                    }
                } else {
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        Text("queue.loading").font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 50)
                }
            }
            .padding(.top, 6)
            .padding(.bottom, 4)
            .frame(minHeight: geometry.size.height, alignment: .top)
            .background(PlayerBackgroundDragRegion())
        }
        .scrollIndicators(.visible)
        }
    }

    private func row(for entry: QueueEntry, isCurrent: Bool) -> some View {
        let track = entry.track ?? (isCurrent && entry.uri == state.currentTrack?.uri ? state.currentTrack : nil)
        let url = track?.artwork?.url
        let label = HStack(spacing: 8) {
            Group {
                if let url, let image = artworkStore.image(for: url) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    ZStack {
                        Color(white: 0.12)
                        Image(systemName: "music.note").foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 32, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(track?.title ?? String(localized: entry.metadataFailed ? "queue.unavailable" : "queue.loadingTrack"))
                    .font(.system(size: 12, weight: isCurrent ? .medium : .regular)).lineLimit(1)
                Text(track?.artists.map(\.name).joined(separator: ", ") ?? "")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isCurrent { Image(systemName: "waveform").font(.system(size: 12)).accessibilityLabel(Text("player.nowPlaying")) }
            Text(track.map { playbackTime($0.durationMs) } ?? "—")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
        }
        .padding(6)
        .contentShape(Rectangle())
        .background(.primary.opacity(isCurrent ? 0.045 : 0), in: RoundedRectangle(cornerRadius: 6))
        return Group {
            if isCurrent { label }
            else {
                Button {
                    onSelect(entry)
                } label: { label }
                .disabled(entry.target == nil || !player.isEngineReady || !state.isActiveDevice)
            }
        }
        .buttonStyle(.songRow)
        .accessibilityElement(children: .combine)
        .task(id: ArtworkLoadRequest(url: url, retryRevision: artworkStore.retryRevision)) { if let url { await artworkStore.load(url) } }
    }
}

#if DEBUG
#Preview("Queue list") {
    let environment = makePreviewEnvironment()
    QueueView(player: environment.player!, artworkStore: environment.artworkStore) { entry in
        if let target = entry.target { environment.player?.selectQueueEntry(target) }
    }
    .frame(width: 332, height: 140)
}
#endif
