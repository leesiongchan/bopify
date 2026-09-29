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
            LazyVStack(spacing: 2) {
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
            .padding(.top, 16)
            .padding(.bottom, 4)
            .frame(minHeight: geometry.size.height, alignment: .top)
            .background(PlayerBackgroundDragRegion())
        }
        .scrollIndicators(.hidden)
        }
    }

    private func row(for entry: QueueEntry, isCurrent: Bool) -> some View {
        let track = entry.track ?? (isCurrent && entry.uri == state.currentTrack?.uri ? state.currentTrack : nil)
        let url = track?.artwork?.url
        let label = HStack(spacing: 12) {
            Group {
                if let url, let image = artworkStore.images[url] {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    ZStack {
                        Color(white: 0.12)
                        Image(systemName: "music.note").foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(track?.title ?? String(localized: entry.metadataFailed ? "queue.unavailable" : "queue.loadingTrack"))
                    .font(.system(size: 13, weight: isCurrent ? .medium : .regular)).lineLimit(1)
                Text(track?.artists.map(\.name).joined(separator: ", ") ?? "")
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isCurrent { Image(systemName: "waveform").font(.system(size: 12)).accessibilityLabel(Text("player.nowPlaying")) }
            Text(track.map { playbackTime($0.durationMs) } ?? "—")
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
        }
        .padding(.vertical, 8).padding(.horizontal, 8)
        .contentShape(Rectangle())
        .background(.white.opacity(isCurrent ? 0.045 : 0), in: RoundedRectangle(cornerRadius: 12))
        return Group {
            if isCurrent { label }
            else {
                Button {
                    onSelect(entry)
                } label: { label }
                .disabled(entry.target == nil || !state.isActiveDevice)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .task(id: url) { if let url { await artworkStore.load(url) } }
    }
}
