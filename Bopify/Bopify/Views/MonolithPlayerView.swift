import SwiftUI
import os
import BopifyDomain
import BopifyLibrary
import BopifyPlayback

struct MonolithPlayerView: View {
    let player: PlayerModel
    let store: ArtworkStore
    let presentation: PlayerPresentation
    let window: MonolithWindowController
    @State private var rotation = RecordRotation()
    @State private var scrub: RecordScrub?
    @State private var pressedAngle: Double?
    @State private var isScrubbing = false
    @State private var previousQueue: PlaybackQueue?
    @State private var pendingSelection: QueueSelectionStatus?
    @AccessibilityFocusState private var accessibilityFocus: Bool
    @Environment(\.favoriteEnvironment) private var environment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var canScrub: Bool { player.state.canSeek && player.state.isActiveDevice && player.displayDurationMs > 0 }
    private var shouldSpin: Bool {
        player.state.phase == .playing && player.state.isActiveDevice && presentation.isVisible && !reduceMotion && pressedAngle == nil
    }
    private var engaged: Bool { presentation.mode != .compact }
    // Bopify's queue says nothing about which way a mirrored device moved.
    private var direction: CarouselDirection {
        guard player.state.mirror == nil else { return .fade }
        return player.state.queue.map { carouselDirection(old: previousQueue, new: $0) } ?? .fade
    }
    private var track: Track? {
        if let mirror = player.state.mirror { return mirror.track }
        guard let current = player.state.queue?.current else { return player.state.currentTrack }
        return current.uri == player.state.currentTrack?.uri ? player.state.currentTrack : current.track
    }
    private var occurrenceID: String {
        player.state.mirror?.trackURI.rawValue ?? player.state.queue?.current?.id ?? player.state.currentTrack?.uri.rawValue ?? "missing"
    }
    private var image: Image? { track?.artwork.flatMap { store.images[$0.url] }.map { Image(nsImage: $0) } }
    private var recordStatus: Text {
        if let notice = player.commandNotice { return Text(notice) }
        return player.state.localizedStatusText
    }
    private var needsAttention: Bool {
        if case .error = player.state.phase { return true }
        return player.commandNotice != nil
    }

    var body: some View {
        let layout = window.layout
        ZStack(alignment: .topLeading) {
            PlayerSurface { PlayerBackgroundDragRegion() }
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .frame(width: layout.sleeveFrame.width, height: layout.sleeveFrame.height)
                .offset(x: layout.sleeveFrame.minX, y: layout.sleeveFrame.minY)
                .opacity(engaged ? 1 : 0)
                .allowsHitTesting(engaged)
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
            if presentation.mode == .expanded, let environment {
                LikedSongsCoverFlow(model: environment.likedSongs, store: store,
                                    play: { player.load(PlayRequest(contextURI: $0.uri)) })
                    .frame(width: layout.lowerFrame.width, height: layout.lowerFrame.height)
                    .offset(x: layout.lowerFrame.minX, y: layout.lowerFrame.minY)
            }
            QueueView(player: player, store: store, select: select)
                .frame(width: layout.lowerFrame.width, height: layout.lowerFrame.height)
                .offset(x: layout.lowerFrame.minX, y: layout.lowerFrame.minY)
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
        .onAppear { window.cancelInteraction = cancelRecord }
        .onDisappear { _ = cancelRecord(); window.cancelInteraction = nil }
        .onChange(of: shouldSpin, initial: true) { _, running in
            rotation.setRunning(running, at: ProcessInfo.processInfo.systemUptime)
        }
        .onChange(of: occurrenceID) { _, _ in _ = cancelRecord() }
        .onChange(of: player.displayDurationMs) { _, _ in _ = cancelRecord() }
        .onChange(of: canScrub) { _, allowed in if !allowed { _ = cancelRecord() } }
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
            if !visible { pendingSelection = nil; accessibilityFocus = false; _ = cancelRecord() }
        }
        .onChange(of: accessibilityFocus) { _, focused in presentation.sendAttention(.accessibilityFocus(focused)) }
        .task(id: track?.artwork?.url) { if let url = track?.artwork?.url { await store.load(url) } }
    }

    private func record(diameter: CGFloat) -> some View {
        VinylRecordView(image: image, occurrenceID: occurrenceID, direction: direction, diameter: diameter,
                        isPlaying: player.state.phase == .playing && player.state.isActiveDevice,
                        isVisible: presentation.isVisible, rotation: rotation,
                        rotationOverride: pressedAngle.map { $0 + (scrub?.angleDelta ?? 0) }, isScrubbing: pressedAngle != nil)
            .overlay {
                RecordPointerRegion(press: { point, geometry in
                    guard presentation.isVisible else { return }
                    let now = ProcessInfo.processInfo.systemUptime
                    rotation.setRunning(false, at: now)
                    pressedAngle = rotation.angle(at: now)
                    if canScrub {
                        scrub = RecordScrub(positionMs: player.displayPositionMs(at: Date()), durationMs: player.displayDurationMs)
                        scrub?.update(x: point.x, y: point.y, geometryID: geometry)
                    }
                }, drag: { point, geometry in
                    guard pressedAngle != nil, canScrub else { return }
                    if !isScrubbing {
                        isScrubbing = true
                        presentation.sendAttention(.interaction(.seek, true))
                        BopifyLog.playback.debug("record scrub began")
                    }
                    scrub?.update(x: point.x, y: point.y, geometryID: geometry)
                }, release: {
                    if isScrubbing, canScrub, presentation.isVisible, let scrub {
                        player.seek(to: scrub.positionMs)
                        BopifyLog.playback.debug("record scrub committed")
                    }
                    _ = cancelRecord()
                })
                .clipShape(Circle())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(track?.title ?? String(localized: "player.unknownTrack")))
                .accessibilityValue(recordStatus)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { window.focus() }
                .accessibilityFocused($accessibilityFocus)
            }
            .overlay {
                if engaged {
                    TimelineView(PlaybackClockSchedule(running: player.isPositionAdvancing && presentation.isVisible, reducedMotion: reduceMotion)) { context in
                        RadialProgressView(positionMs: isScrubbing ? (scrub?.positionMs ?? 0) : player.displayPositionMs(at: context.date), durationMs: player.displayDurationMs,
                                           canSeek: player.state.canSeek && player.state.isActiveDevice,
                                           seek: player.seek(to:), interactionChanged: { presentation.sendAttention(.interaction(.seek, $0)) },
                                           isVisible: presentation.isVisible, showsTime: false, pointerEnabled: false)
                            .allowsHitTesting(false)
                            .id(occurrenceID)
                    }
                }
            }
            .overlay {
                if needsAttention {
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
                    .background(PlayerBackgroundDragRegion())
                // Hidden while mirroring: Bopify still has its own track, and the heart would show that track's saved state.
                if player.state.mirror == nil {
                    FavoriteButton()
                        .disabled(track?.uri != player.state.currentTrack?.uri)
                }
            }
            TransportControls(state: player.state, model: player)
                .frame(maxWidth: .infinity)
            TimelineView(PlaybackClockSchedule(running: player.isPositionAdvancing && presentation.isVisible, reducedMotion: true)) { context in
                HStack {
                    Text(playbackTime(isScrubbing ? (scrub?.positionMs ?? 0) : player.displayPositionMs(at: context.date)))
                    Spacer()
                    Text(playbackTime(player.displayDurationMs))
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
                VolumeControl(player: player, presentation: presentation)
                Button { presentation.requestQueue(presentation.mode != .queue) } label: {
                    Image(systemName: "music.note.list").frame(width: 28, height: 28)
                }.accessibilityLabel(Text("queue.title"))
                    .disabled(player.state.mirror != nil && presentation.mode != .queue)
            }
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
            case .idle: player.state.localizedStatusText
            case .ended: Text("player.ended")
            default: EmptyView()
            }
        }
    }

    @discardableResult private func cancelRecord() -> Bool {
        guard let pressedAngle else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        rotation.setAngle(pressedAngle + (scrub?.angleDelta ?? 0), at: now)
        self.pressedAngle = nil
        scrub = nil
        if isScrubbing { presentation.sendAttention(.interaction(.seek, false)) }
        isScrubbing = false
        rotation.setRunning(shouldSpin, at: now)
        return true
    }

    private func select(_ entry: QueueEntry) {
        guard let target = entry.target else { return }
        pendingSelection = .pending(entryID: entry.id, target: target)
        player.selectQueueEntry(target)
    }
}

struct RecordPointerRegion: NSViewRepresentable {
    var press: (CGPoint, UInt64) -> Void
    var drag: (CGPoint, UInt64) -> Void
    var release: () -> Void
    func makeNSView(context: Context) -> PointerView { PointerView() }
    func updateNSView(_ view: PointerView, context: Context) {
        view.press = press; view.drag = drag; view.release = release
    }
    final class PointerView: NSView {
        var press: ((CGPoint, UInt64) -> Void)?
        var drag: ((CGPoint, UInt64) -> Void)?
        var release: (() -> Void)?
        private var origin: CGPoint?
        private var dragging = false
        private var geometry: CGRect?
        private var geometryID: UInt64 = 0
        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? {
            let local = convert(point, from: superview)
            return hypot(local.x - bounds.midX, local.y - bounds.midY) <= bounds.width / 2 ? self : nil
        }
        private func sample(_ event: NSEvent) -> (CGPoint, UInt64) {
            let point = convert(event.locationInWindow, from: nil)
            let centerInWindow = convert(CGPoint(x: bounds.midX, y: bounds.midY), to: nil)
            let centerOnScreen = window?.convertPoint(toScreen: centerInWindow) ?? centerInWindow
            let next = CGRect(origin: centerOnScreen, size: bounds.size)
            if next != geometry { geometry = next; geometryID &+= 1 }
            return (CGPoint(x: point.x - bounds.midX, y: point.y - bounds.midY), geometryID)
        }
        override func mouseDown(with event: NSEvent) {
            origin = window?.convertPoint(toScreen: event.locationInWindow)
            dragging = false
            let (point, geometry) = sample(event)
            press?(point, geometry)
            window?.makeKey()
        }
        override func mouseDragged(with event: NSEvent) {
            guard let origin, let screen = window?.convertPoint(toScreen: event.locationInWindow),
                  dragging || hypot(screen.x - origin.x, screen.y - origin.y) > 4 else { return }
            dragging = true
            let (point, geometry) = sample(event)
            drag?(point, geometry)
        }
        override func mouseUp(with event: NSEvent) { origin = nil; dragging = false; release?() }
    }
}
