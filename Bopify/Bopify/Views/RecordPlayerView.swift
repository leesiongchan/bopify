import SwiftUI
import os
import BopifyDomain
import BopifyLibrary
import BopifyPlayback

enum RecordMotorRequest: String {
    case drive, brake, snap

    static func resolve(phase: PlaybackPhase, ready: Bool, active: Bool, visible: Bool, reduced: Bool, pressed: Bool) -> Self {
        guard ready, visible, !reduced, !pressed else { return .snap }
        switch phase {
        case .loading, .buffering: return .snap
        case .idle: return active ? .snap : .brake
        case .playing: return active ? .drive : .brake
        case .paused, .ended, .error: return .brake
        }
    }
}

struct RecordPlayerView: View {
    let player: PlayerModel
    let artworkStore: ArtworkStore
    let presentation: PlayerPresentation
    let windowController: PlayerWindowController
    @State private var rotation = RecordRotation()
    @State private var isCoasting = false
    @State private var appliedMotorRequest: RecordMotorRequest?
    @State private var displayedPressing = PressingAppearance.neutral
    @State private var scrub: RecordScrub?
    @State private var pressedAngle: Double?
    @State private var isScrubbing = false
    @State private var pendingSelection: QueueSelectionStatus?
    @State private var controlsContentHeight: CGFloat?
    @AccessibilityFocusState private var accessibilityFocus: Bool
    @Environment(AppEnvironment.self) private var environment: AppEnvironment?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var canScrub: Bool { player.isEngineReady && player.state.canSeek && player.state.isActiveDevice && player.displayDurationMs > 0 }
    private var motorRequest: RecordMotorRequest {
        .resolve(phase: player.state.phase, ready: player.isEngineReady, active: player.state.isActiveDevice,
                 visible: presentation.isVisible, reduced: reduceMotion, pressed: pressedAngle != nil)
    }
    private var isMoving: Bool {
        motorRequest != .snap && (motorRequest == .drive || isCoasting) && rotation.isMoving(at: ProcessInfo.processInfo.systemUptime)
    }
    private var isEngaged: Bool { presentation.mode != .compact }
    // Bopify's queue says nothing about which way a mirrored device moved.
    private var direction: CarouselDirection {
        guard player.state.mirror == nil else { return .fade }
        return player.queueDirection
    }
    private var track: Track? {
        if let mirror = player.state.mirror { return mirror.track }
        guard let current = player.state.queue?.current else { return player.state.currentTrack }
        return current.uri == player.state.currentTrack?.uri ? player.state.currentTrack : current.track
    }
    private var occurrenceID: String {
        player.state.mirror?.trackURI.rawValue ?? player.state.queue?.current?.id ?? player.state.currentTrack?.uri.rawValue ?? "missing"
    }
    private var image: Image? { track?.artwork.flatMap { artworkStore.image(for: $0.url) }.map { Image(nsImage: $0) } }
    private struct PressingRequest: Equatable {
        let uri: String?
        let artworkURL: URL?
        let retryRevision: Int
        let hasImage: Bool
    }
    private var pressingRequest: PressingRequest {
        PressingRequest(uri: player.state.mirror?.trackURI.rawValue ?? track?.uri.rawValue ?? player.state.queue?.current?.uri?.rawValue,
                        artworkURL: track?.artwork?.url, retryRevision: artworkStore.retryRevision,
                        hasImage: track?.artwork.flatMap { artworkStore.image(for: $0.url) } != nil)
    }
    private var recordStatus: Text {
        if let connectionStatus, connectionStatus.isVisible { return connectionStatus.message }
        if let notice = player.commandNotice { return Text(notice) }
        return player.state.localizedStatusText
    }
    private var connectionStatus: PlaybackConnectionStatusView? {
        guard let environment else { return nil }
        return PlaybackConnectionStatusView(status: environment.connectionStatus, restorationUnavailable: player.restorationUnavailable,
            onRetry: environment.retryPlaybackConnection, onReconnect: { Task { await environment.reconnectSpotify() } },
            isAuthorizing: environment.isAuthorizingPlayback, onCancel: environment.cancelPlaybackAuthorization)
    }
    private var needsAttention: Bool {
        if let connectionStatus, connectionStatus.isVisible { return false }
        if case .error = player.state.phase { return true }
        return player.commandNotice != nil
    }

    var body: some View {
        let layout = windowController.layout
        ZStack(alignment: .topLeading) {
            PlayerSurface(cornerRadius: layout.sleeveCornerRadius) { PlayerBackgroundDragRegion() }
                .clipShape(RoundedRectangle(cornerRadius: layout.sleeveCornerRadius, style: .continuous))
                .frame(width: layout.sleeveFrame.width, height: layout.sleeveFrame.height)
                .offset(x: layout.sleeveFrame.minX, y: layout.sleeveFrame.minY)
                .opacity(isEngaged ? 1 : 0)
                // Appears instantly hidden behind the record; on collapse it fades only once mostly folded back into it.
                .animation(isEngaged || reduceMotion ? nil : .easeIn(duration: 0.12).delay(0.3), value: isEngaged)
                .allowsHitTesting(isEngaged)
            ScrollView(layout.controlsFrame.width < 156 ? [.horizontal, .vertical] : .vertical) {
                // The scroll view swallows clicks on blank space, so the drag region must live inside it.
                controls.frame(minWidth: 156)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { controlsContentHeight = $0 }
                    .frame(minHeight: layout.controlsFrame.height, alignment: .top)
                    .background(PlayerBackgroundDragRegion())
            }
            .scrollIndicators(.hidden)
            .frame(width: layout.controlsFrame.width, height: layout.controlsFrame.height)
            .offset(x: layout.controlsFrame.minX, y: layout.controlsFrame.minY)
            .allowsHitTesting(isEngaged)
            .disabled(!isEngaged)
            .accessibilityHidden(!isEngaged)
            .accessibilityFocused($accessibilityFocus)
            if presentation.mode == .expanded, let environment {
                // The shelf starts just under the controls' content, so its tabs sit with the controls instead of below their spare height.
                let top = controlsContentHeight.map { min(layout.lowerFrame.minY, layout.controlsFrame.minY + $0 + 4) } ?? layout.lowerFrame.minY
                LibraryShelf(environment: environment, artworkStore: artworkStore,
                             tabsInset: layout.controlsFrame.minX - layout.lowerFrame.minX,
                             coverBleed: layout.lowerFrame.minX - layout.sleeveFrame.minX, onPlay: { player.load($0) })
                    .frame(width: layout.lowerFrame.width, height: layout.lowerFrame.maxY - top)
                    .offset(x: layout.lowerFrame.minX, y: top)
            }
            QueueView(player: player, artworkStore: artworkStore, onSelect: select)
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
        .offset(x: windowController.contentOffset.x, y: windowController.contentOffset.y)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { windowController.onCancelInteraction = cancelRecord }
        .onDisappear { _ = cancelRecord(); setMotor(.snap); windowController.onCancelInteraction = nil }
        .onChange(of: motorRequest, initial: true) { _, request in setMotor(request) }
        .task(id: rotation.stopTime) {
            guard isCoasting, let deadline = rotation.stopTime else { return }
            do { try await Task.sleep(for: .seconds(max(0, deadline - ProcessInfo.processInfo.systemUptime))) }
            catch { return }
            guard rotation.stopTime == deadline else { return }
            isCoasting = false
        }
        .onChange(of: occurrenceID) { _, _ in _ = cancelRecord() }
        .onChange(of: player.displayDurationMs) { _, _ in _ = cancelRecord() }
        .onChange(of: canScrub) { _, allowed in if !allowed { _ = cancelRecord() } }
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
        .onChange(of: track?.artwork.flatMap { artworkStore.palette(for: $0.url) }) { _, palette in
            guard let palette else { return }
            displayedPressing = PressingAppearance(seed: pressingRequest.uri.map(PressingSeed.offset) ?? 0, palette: palette)
        }
        .task(id: pressingRequest) {
            let request = pressingRequest
            if let url = request.artworkURL { await artworkStore.loadPalette(url) }
            guard !Task.isCancelled, request == pressingRequest else { return }
            let palette = request.artworkURL.flatMap { artworkStore.palette(for: $0) } ?? .neutral
            let ready = PressingAppearance(seed: request.uri.map(PressingSeed.offset) ?? 0, palette: palette)
            displayedPressing = ready
        }
    }

    private func record(diameter: CGFloat) -> some View {
        VinylRecordView(image: image, occurrenceID: occurrenceID, direction: direction, diameter: diameter,
                        isMoving: isMoving,
                        isVisible: presentation.isVisible, rotation: rotation,
                        pressingSeed: displayedPressing.seed, palette: displayedPressing.palette,
                        rotationOverride: pressedAngle.map { $0 + (scrub?.angleDelta ?? 0) }, isScrubbing: pressedAngle != nil,
                        isEngaged: isEngaged, reduceMotionOverride: reduceMotion)
            .overlay {
                RecordPointerRegion(onPress: { point, geometryID in
                    guard presentation.isVisible else { return }
                    let now = ProcessInfo.processInfo.systemUptime
                    setMotor(.snap, at: now)
                    pressedAngle = rotation.angle(at: now)
                    if canScrub {
                        scrub = RecordScrub(positionMs: player.displayPositionMs(at: Date()), durationMs: player.displayDurationMs)
                        scrub?.update(x: point.x, y: point.y, geometryID: geometryID)
                    }
                }, onDrag: { point, geometryID in
                    guard pressedAngle != nil, canScrub else { return }
                    if !isScrubbing {
                        isScrubbing = true
                        presentation.sendAttention(.interaction(.seek, true))
                        BopifyLog.playback.debug("record scrub began")
                    }
                    scrub?.update(x: point.x, y: point.y, geometryID: geometryID)
                }, onRelease: {
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
                .accessibilityAction { windowController.focus() }
                .accessibilityFocused($accessibilityFocus)
            }
            .overlay {
                if isEngaged {
                    TimelineView(PlaybackClockSchedule(isRunning: player.isPositionAdvancing && presentation.isVisible, reduceMotion: reduceMotion)) { context in
                        RadialProgressView(positionMs: isScrubbing ? (scrub?.positionMs ?? 0) : player.displayPositionMs(at: context.date), durationMs: player.displayDurationMs,
                                           canSeek: player.isEngineReady && player.state.canSeek && player.state.isActiveDevice,
                                           onSeek: player.seek(to:), onInteractionChanged: { presentation.sendAttention(.interaction(.seek, $0)) },
                                           isVisible: presentation.isVisible, showsTime: false, isPointerEnabled: false)
                            .allowsHitTesting(false)
                            .id(occurrenceID)
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if !isEngaged, let connectionStatus, connectionStatus.isVisible {
                    CompactPlaybackConnectionMenu(connection: connectionStatus)
                        .frame(width: diameter - 24, height: 24)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 12)
                }
            }
            .overlay {
                if needsAttention {
                    Circle().strokeBorder(.black.opacity(0.75), lineWidth: 3)
                        .overlay(Circle().strokeBorder(.orange.opacity(0.7), lineWidth: 1))
                        .allowsHitTesting(false)
                }
            }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 4) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(track?.title ?? String(localized: "player.unknownTrack"))
                        .font(.system(size: 17, weight: .medium)).lineLimit(1).help(track?.title ?? "")
                    if let track {
                        ArtistSongsButton(track: track, player: player, artworkStore: artworkStore, presentation: presentation)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                // Hidden while mirroring: Bopify still has its own track, and the heart would show that track's saved state.
                if player.state.mirror == nil {
                    FavoriteButton()
                        .disabled(track?.uri != player.state.currentTrack?.uri)
                }
            }
            .modifier(UnfurlRow(index: 0, isEngaged: isEngaged, reduceMotion: reduceMotion))
            TransportControls(player: player)
                .frame(maxWidth: .infinity)
                .modifier(UnfurlRow(index: 1, isEngaged: isEngaged, reduceMotion: reduceMotion))
            TimelineView(PlaybackClockSchedule(isRunning: player.isPositionAdvancing && presentation.isVisible, reduceMotion: true)) { context in
                HStack {
                    Text(playbackTime(isScrubbing ? (scrub?.positionMs ?? 0) : player.displayPositionMs(at: context.date)))
                    Spacer()
                    Text(playbackTime(player.displayDurationMs))
                }.font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            }
            .modifier(UnfurlRow(index: 2, isEngaged: isEngaged, reduceMotion: reduceMotion))
            HStack(spacing: 4) {
                Button { player.setShuffle(!player.state.shuffleEnabled) } label: {
                    Image(systemName: "shuffle").frame(width: 28, height: 28)
                        .symbolEffect(.bounce, value: reduceMotion ? false : player.state.shuffleEnabled)
                }.buttonStyle(.playerToggle(isOn: player.state.shuffleEnabled, dimsWhenOff: true))
                    .accessibilityLabel(Text("transport.shuffle"))
                    .accessibilityValue(Text(player.state.shuffleEnabled ? "control.on" : "control.off"))
                    .disabled(!player.isEngineReady || !player.state.isActiveDevice)
                Button {
                    player.setRepeat(player.state.repeatMode == .off ? .context : player.state.repeatMode == .context ? .track : .off)
                } label: {
                    Image(systemName: player.state.repeatMode == .track ? "repeat.1" : "repeat").frame(width: 28, height: 28)
                        .contentTransition(.symbolEffect(.replace))
                }.buttonStyle(.playerToggle(isOn: player.state.repeatMode != .off, dimsWhenOff: true))
                    .accessibilityLabel(Text("transport.repeat"))
                    .accessibilityValue(Text(player.state.repeatMode == .off ? "control.off" : player.state.repeatMode == .track ? "transport.repeat.track" : "transport.repeat.context"))
                    .disabled(!player.isEngineReady || !player.state.isActiveDevice)
                Spacer(minLength: 0)
                VolumeControl(player: player, presentation: presentation)
                if let environment {
                    Button { environment.toggleLiveLyrics() } label: {
                        Image(systemName: "quote.bubble").frame(width: 28, height: 28)
                    }.buttonStyle(.playerToggle(isOn: environment.isLiveLyricsVisible))
                        .accessibilityLabel(String(localized: "control.title", defaultValue: "Lyrics", table: "LyricRibbon"))
                        .accessibilityValue(Text(environment.isLiveLyricsVisible ? "control.on" : "control.off"))
                        .help(String(localized: "control.help", defaultValue: "Show or hide lyrics (⌃⌥L)", table: "LyricRibbon"))
                        .contextMenu {
                            Button(String(localized: "menu.focus", table: "LyricRibbon")) { environment.focusLiveLyrics() }
                        }
                        .disabled(environment.isPreparingForQuit || environment.authState != .signedIn)
                }
                Button { presentation.requestQueue(presentation.mode != .queue) } label: {
                    Image(systemName: "music.note.list").frame(width: 28, height: 28)
                }.buttonStyle(.playerToggle(isOn: presentation.mode == .queue))
                    .accessibilityLabel(Text("queue.title"))
                    .accessibilityValue(Text(presentation.mode == .queue ? "control.on" : "control.off"))
                    .disabled(player.state.mirror != nil && presentation.mode != .queue)
            }
            .modifier(UnfurlRow(index: 3, isEngaged: isEngaged, reduceMotion: reduceMotion))
            // The status keeps its line while empty so the library tabs below don't jump each time a track loads.
            ZStack(alignment: .leading) { Text(verbatim: " ").hidden(); status }
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .modifier(UnfurlRow(index: 4, isEngaged: isEngaged, reduceMotion: reduceMotion))
        }
        .buttonStyle(.playerControl)
        .onDisappear { presentation.sendAttention(.interaction(.volume, false)) }
    }

    @ViewBuilder private var status: some View {
        if let connectionStatus, connectionStatus.isVisible { connectionStatus }
        else if let notice = player.commandNotice { Text(notice) }
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
        setMotor(motorRequest, at: now)
        return true
    }

    private func setMotor(_ request: RecordMotorRequest, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        rotation.setRunning(request == .drive, at: time, stopStyle: request == .snap ? .snap : .brake)
        isCoasting = request == .brake && rotation.isMoving(at: time)
        if appliedMotorRequest != request {
            BopifyLog.playback.debug("record motor \(request.rawValue, privacy: .public)")
            appliedMotorRequest = request
        }
    }

    private func select(_ entry: QueueEntry) {
        guard let target = entry.target else { return }
        pendingSelection = .pending(entryID: entry.id, target: target)
        player.selectQueueEntry(target)
    }
}

/// Cascades a control row in after the sleeve starts unfurling; all rows leave together so a quick flick never strands one.
private struct UnfurlRow: ViewModifier {
    let index: Int
    let isEngaged: Bool
    let reduceMotion: Bool
    func body(content: Content) -> some View {
        let settled = isEngaged || reduceMotion
        content
            .opacity(isEngaged ? 1 : 0)
            .blur(radius: settled ? 0 : 6)
            .offset(x: settled ? 0 : -14)
            .animation(reduceMotion ? nil : isEngaged ? .spring(duration: 0.4, bounce: 0.1).delay(0.12 + Double(index) * 0.04)
                                                      : .easeOut(duration: 0.12), value: isEngaged)
    }
}

struct RecordPointerRegion: NSViewRepresentable {
    var onPress: (_ point: CGPoint, _ geometryID: UInt64) -> Void
    var onDrag: (_ point: CGPoint, _ geometryID: UInt64) -> Void
    var onRelease: () -> Void
    func makeNSView(context: Context) -> PointerView { PointerView() }
    func updateNSView(_ view: PointerView, context: Context) {
        view.onPress = onPress; view.onDrag = onDrag; view.onRelease = onRelease
    }
    final class PointerView: NSView {
        var onPress: ((_ point: CGPoint, _ geometryID: UInt64) -> Void)?
        var onDrag: ((_ point: CGPoint, _ geometryID: UInt64) -> Void)?
        var onRelease: (() -> Void)?
        private var origin: CGPoint?
        private var isDragging = false
        private var geometry: CGRect?
        private var geometryID: UInt64 = 0
        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? {
            let local = convert(point, from: superview)
            return hypot(local.x - bounds.midX, local.y - bounds.midY) <= bounds.width / 2 ? self : nil
        }
        private func sample(_ event: NSEvent) -> (point: CGPoint, geometryID: UInt64) {
            let point = convert(event.locationInWindow, from: nil)
            let centerInWindow = convert(CGPoint(x: bounds.midX, y: bounds.midY), to: nil)
            let centerOnScreen = window?.convertPoint(toScreen: centerInWindow) ?? centerInWindow
            let next = CGRect(origin: centerOnScreen, size: bounds.size)
            if next != geometry { geometry = next; geometryID &+= 1 }
            return (CGPoint(x: point.x - bounds.midX, y: point.y - bounds.midY), geometryID)
        }
        override func mouseDown(with event: NSEvent) {
            origin = window?.convertPoint(toScreen: event.locationInWindow)
            isDragging = false
            let location = sample(event)
            onPress?(location.point, location.geometryID)
            window?.makeKey()
        }
        override func mouseDragged(with event: NSEvent) {
            guard let origin, let screen = window?.convertPoint(toScreen: event.locationInWindow),
                  isDragging || hypot(screen.x - origin.x, screen.y - origin.y) > 4 else { return }
            isDragging = true
            let location = sample(event)
            onDrag?(location.point, location.geometryID)
        }
        override func mouseUp(with event: NSEvent) { origin = nil; isDragging = false; onRelease?() }
    }
}

#if DEBUG
#Preview("Playing") { previewRecordPlayer(.playing) }
#Preview("Paused") { previewRecordPlayer(.paused) }
#Preview("Loading") { previewRecordPlayer(.loading) }
#Preview("Playback error") { previewRecordPlayer(.playbackError) }
#Preview("Mirroring another device") { previewRecordPlayer(.mirroring) }
#Preview("Queue") { previewRecordPlayer(.playing, mode: .queue) }
#Preview("Resting") { previewRecordPlayer(.playing, mode: .compact) }
#endif
