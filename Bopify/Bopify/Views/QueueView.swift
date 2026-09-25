import SwiftUI
import BopifyDomain
import BopifyPlayback

struct QueueView: View {
    let player: PlayerModel
    let state: PlaybackState
    let store: ArtworkStore
    let presentation: PlayerPresentation
    let artworkNamespace: Namespace.ID

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                if let queue = state.queue {
                    if let current = queue.current { row(current, current: true) }
                    ForEach(queue.next) { entry in row(entry, current: false) }
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
            .padding(.bottom, 98)
        }
        .scrollIndicators(.hidden)
        .overlay(alignment: .bottom) {
            VStack(spacing: 6) {
                if let notice = player.commandNotice {
                    Text(notice).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                CompactPlayerView(player: player, state: state, store: store, presentation: presentation, artworkNamespace: artworkNamespace)
            }
            .padding(.top, 14)
            .background(LinearGradient(colors: [.clear, Color(red: 8.0 / 255, green: 9.0 / 255, blue: 13.0 / 255)], startPoint: .top, endPoint: .bottom))
        }
    }

    private func row(_ entry: QueueEntry, current: Bool) -> some View {
        let track = entry.track ?? (current && entry.uri == state.currentTrack?.uri ? state.currentTrack : nil)
        let url = track?.artwork?.url
        return Button {
            if let target = entry.target { player.selectQueueEntry(target) }
        } label: {
            HStack(spacing: 12) {
                Group {
                    if let url, let image = store.images[url] {
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
                        .font(.system(size: 13, weight: current ? .medium : .regular)).lineLimit(1)
                    Text(track?.artists.map(\.name).joined(separator: ", ") ?? "")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if current { Image(systemName: "waveform").font(.system(size: 12)).accessibilityLabel(Text("player.nowPlaying")) }
                Text(track.map { playbackTime($0.durationMs) } ?? "—")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            .padding(.vertical, 8).padding(.horizontal, 8)
            .contentShape(Rectangle())
            .background(.white.opacity(current ? 0.045 : 0), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(!current && (entry.target == nil || !state.isActiveDevice))
        .accessibilityElement(children: .combine)
        .task(id: url) { if let url { await store.load(url) } }
    }
}
