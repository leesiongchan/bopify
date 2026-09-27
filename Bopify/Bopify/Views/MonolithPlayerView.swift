import SwiftUI
import BopifyDomain
import BopifyPlayback

struct MonolithPlayerView: View {
    let player: PlayerModel
    let store: ArtworkStore
    let presentation: PlayerPresentation
    let window: MonolithWindowController
    @State private var previousQueue: PlaybackQueue?
    @State private var pendingSelection: QueueSelectionStatus?
    @AccessibilityFocusState private var accessibilityFocus: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var engaged: Bool { presentation.mode != .compact }
    private var direction: CarouselDirection {
        player.state.queue.map { carouselDirection(old: previousQueue, new: $0) } ?? .fade
    }
    private var track: Track? {
        guard let current = player.state.queue?.current else { return player.state.currentTrack }
        return current.uri == player.state.currentTrack?.uri ? player.state.currentTrack : current.track
    }
    private var occurrenceID: String { player.state.queue?.current?.id ?? player.state.currentTrack?.uri.rawValue ?? "missing" }
    private var image: Image? { track?.artwork.flatMap { store.images[$0.url] }.map { Image(nsImage: $0) } }

    var body: some View {
        let layout = window.layout
        ZStack(alignment: .topLeading) {
            PlayerSurface { Color.clear }
                .frame(width: layout.sleeveFrame.width, height: layout.sleeveFrame.height)
                .offset(x: layout.sleeveFrame.minX, y: layout.sleeveFrame.minY)
                .opacity(engaged ? 1 : 0)
                .allowsHitTesting(false)
            ScrollView(layout.controlsFrame.width < 144 ? [.horizontal, .vertical] : .vertical) {
                controls.frame(minWidth: 144)
            }
            .scrollIndicators(.hidden)
            .frame(width: layout.controlsFrame.width, height: layout.controlsFrame.height)
            .offset(x: layout.controlsFrame.minX, y: layout.controlsFrame.minY)
            .opacity(engaged ? 1 : 0)
            .allowsHitTesting(engaged)
            .disabled(!engaged)
            .accessibilityHidden(!engaged)
            .accessibilityFocused($accessibilityFocus)
            QueueView(player: player, store: store, select: select)
                .frame(width: layout.queueFrame.width, height: layout.queueFrame.height)
                .offset(x: layout.queueFrame.minX, y: layout.queueFrame.minY)
                .opacity(presentation.mode == .queue ? 1 : 0)
                .allowsHitTesting(presentation.mode == .queue)
                .disabled(presentation.mode != .queue)
                .accessibilityHidden(presentation.mode != .queue)
            record(diameter: layout.recordDiameter)
                .position(layout.recordCenter)
        }
        .frame(width: layout.contentSize.width, height: layout.contentSize.height, alignment: .topLeading)
        .offset(x: window.contentOffset.x, y: window.contentOffset.y)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: player.state.queue, initial: true) { _, next in previousQueue = next }
        .onChange(of: player.queueSelection) { _, selection in
            guard case let .confirmed(id, target) = selection,
                  pendingSelection == .pending(entryID: id, target: target) else { return }
            pendingSelection = nil
            presentation.requestQueue(false)
        }
        .onChange(of: presentation.mode) { _, mode in
            if mode != .queue { pendingSelection = nil }
        }
        .onChange(of: presentation.isVisible) { _, visible in
            if !visible { pendingSelection = nil; accessibilityFocus = false }
        }
        .onChange(of: accessibilityFocus) { _, focused in presentation.sendAttention(.accessibilityFocus(focused)) }
        .task(id: track?.artwork?.url) { if let url = track?.artwork?.url { await store.load(url) } }
    }

    private func record(diameter: CGFloat) -> some View {
        VinylRecordView(image: image, occurrenceID: occurrenceID, direction: direction, diameter: diameter,
                        isPlaying: player.state.phase == .playing, isVisible: presentation.isVisible)
            .overlay {
                RecordDragRegion().clipShape(Circle()).padding(18)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(track?.title ?? String(localized: "player.unknownTrack")))
                    .accessibilityValue(Text(player.state.phase == .playing ? "transport.state.playing" : "transport.state.paused"))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { window.focus() }
                    .accessibilityFocused($accessibilityFocus)
            }
            .overlay {
                if engaged {
                    TimelineView(PlaybackClockSchedule(running: player.state.phase == .playing && presentation.isVisible, reducedMotion: reduceMotion)) { context in
                        RadialProgressView(positionMs: player.displayPositionMs(at: context.date), durationMs: player.state.durationMs,
                                           canSeek: player.state.canSeek && player.state.isActiveDevice,
                                           seek: player.seek(to:), interactionChanged: { presentation.sendAttention(.interaction(.seek, $0)) },
                                           isVisible: presentation.isVisible, showsTime: false)
                            .id(occurrenceID)
                    }
                }
            }
            .overlay {
                if player.commandNotice != nil || !player.state.isActiveDevice {
                    Circle().strokeBorder(.orange.opacity(0.7), lineWidth: 1).allowsHitTesting(false)
                }
            }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 4) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(track?.title ?? String(localized: "player.unknownTrack"))
                        .font(.system(size: 17, weight: .medium)).lineLimit(1).help(track?.title ?? "")
                    Text(track?.artists.map(\.name).joined(separator: ", ") ?? "")
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        .help(track?.artists.map(\.name).joined(separator: ", ") ?? "")
                }.frame(maxWidth: .infinity, alignment: .leading)
                FavoriteButton(detailsChanged: { presentation.sendAttention(.interaction(.popover, $0)) })
                    .disabled(track?.uri != player.state.currentTrack?.uri)
            }
            TransportControls(state: player.state, model: player)
                .frame(maxWidth: .infinity)
            TimelineView(PlaybackClockSchedule(running: player.state.phase == .playing && presentation.isVisible, reducedMotion: true)) { context in
                HStack {
                    Text(playbackTime(player.displayPositionMs(at: context.date)))
                    Spacer()
                    Text(playbackTime(player.state.durationMs))
                }.font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                Button { player.setShuffle(!player.state.shuffleEnabled) } label: {
                    Image(systemName: "shuffle").frame(width: 28, height: 28)
                        .foregroundStyle(player.state.shuffleEnabled ? .primary : .secondary)
                }.accessibilityLabel(Text("transport.shuffle"))
                    .accessibilityValue(Text(player.state.shuffleEnabled ? "control.on" : "control.off"))
                    .disabled(!player.state.isActiveDevice)
                Button {
                    player.setRepeat(player.state.repeatMode == .off ? .context : player.state.repeatMode == .context ? .track : .off)
                } label: {
                    Image(systemName: player.state.repeatMode == .track ? "repeat.1" : "repeat").frame(width: 28, height: 28)
                        .foregroundStyle(player.state.repeatMode == .off ? .secondary : .primary)
                }.accessibilityLabel(Text("transport.repeat"))
                    .accessibilityValue(Text(player.state.repeatMode == .off ? "control.off" : player.state.repeatMode == .track ? "transport.repeat.track" : "transport.repeat.context"))
                    .disabled(!player.state.isActiveDevice)
                Spacer(minLength: 0)
                Button { presentation.requestQueue(presentation.mode != .queue) } label: {
                    Image(systemName: "music.note.list").frame(width: 28, height: 28)
                }.accessibilityLabel(Text("queue.title"))
            }
            HStack(spacing: 8) {
                Button(action: player.toggleMute) {
                    Image(systemName: player.state.volume == 0 ? "speaker.slash" : "speaker.wave.2")
                        .frame(width: 28, height: 28)
                }.accessibilityLabel(Text(player.state.volume == 0 ? "transport.unmute" : "transport.mute"))
                Slider(value: Binding(get: { player.state.volume }, set: player.setVolume), in: 0...1,
                       onEditingChanged: { presentation.sendAttention(.interaction(.volume, $0)) }) { Text("transport.volume") }
                    .labelsHidden()
            }.disabled(!player.state.isActiveDevice)
            status.font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(PlayerControlStyle())
        .onDisappear { presentation.sendAttention(.interaction(.volume, false)) }
    }

    @ViewBuilder private var status: some View {
        if let notice = player.commandNotice { Text(notice) }
        else {
            switch player.state.phase {
            case .loading, .buffering:
                HStack(spacing: 5) { ProgressView().controlSize(.mini); Text(player.state.phase == .loading ? "player.loading" : "player.buffering") }
            case let .error(error): error.localizedText
            case .idle: Text("player.inactiveDevice.title")
            case .ended: Text("player.ended")
            default: EmptyView()
            }
        }
    }

    private func select(_ entry: QueueEntry) {
        guard let target = entry.target else { return }
        pendingSelection = .pending(entryID: entry.id, target: target)
        player.selectQueueEntry(target)
    }
}
