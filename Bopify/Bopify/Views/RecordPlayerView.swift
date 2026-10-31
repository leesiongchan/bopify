import SwiftUI
import os
import BopifyDomain
import BopifyLibrary
import BopifyPlayback

enum RecordMotorRequest: String {
    case drive, brake, snap

    static func resolve(phase: PlaybackPhase, ready: Bool, active: Bool, visible: Bool, reduced: Bool, pressed: Bool,
                        loadingFromPlaying: Bool = false) -> Self {
        guard ready, visible, !reduced, !pressed else { return .snap }
        switch phase {
        case .loading: return loadingFromPlaying ? .drive : .snap
        case .idle: return active ? .snap : .brake
        case .playing: return active ? .drive : .brake
        case .paused, .ended, .error: return .brake
        }
    }
}

struct RecordPlayerView: View {
    private struct OutgoingRecordAppearance {
        let image: Image?
        let occurrenceID: String
        let labelRatio: CGFloat
        let pressing: PressingAppearance
        let artworkRotationOffset: Double
    }

    let player: PlayerModel
    let artworkStore: ArtworkStore
    let presentation: PlayerPresentation
    let windowController: PlayerWindowController
    var lyricModel: LyricRibbonModel? = nil
    var onLyricSeek: ((Int64, LyricPlaybackSnapshot) -> Void)? = nil
    @State private var rotation = RecordRotation()
    @State private var isCoasting = false
    @State private var appliedMotorRequest: RecordMotorRequest?
    @State private var loadedArtwork: LoadedArtwork?
    @State private var loadedArtworkRequest: ArtworkLoadRequest?
    @State private var displayedOccurrenceID = "missing"
    @State private var displayedPressing = PressingAppearance.neutral
    @State private var scrub: RecordScrub?
    @State private var pressedAngle: Double?
    @State private var isScrubbing = false
    @State private var isRecordHovered = false
    @AppStorage("record.hasScrubbed") private var hasScrubbed = false
    @AppStorage("player.artworkBackground") private var showsArtworkBackground = true
    @AppStorage(VinylDesign.preferenceKey) private var designRawValue = VinylDesign.original.rawValue
    @State private var designSelection = VinylDesignSelection()
    @AppStorage(RecordDesign.preferenceKey) private var recordDesignRawValue = RecordDesign.classic.rawValue
    @State private var recordDesignSelection = RecordDesignSelection()
    @State private var pendingSelection: QueueSelectionStatus?
    @State private var controlsContentHeight: CGFloat?
    @State private var coverLaunch: CoverFlowLaunch?
    @State private var dockedCoverRatio: CGFloat = 0.43
    @State private var artworkRotationOffset = 0.0
    @State private var showsCoverFunnel = false
    @State private var loadingFromPlaying = false
    @State private var coverRotationOffset = 0.0
    @State private var coverTiming: RecordLoadTiming?
    @State private var coverStartRevision: UInt64 = 0
    @State private var coverEngineEpoch: UInt64 = 0
    @State private var outgoingRecord: OutgoingRecordAppearance?
    @AccessibilityFocusState private var accessibilityFocus: Bool
    @Environment(AppEnvironment.self) private var environment: AppEnvironment?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var canScrub: Bool { player.isEngineReady && player.state.canSeek && player.state.isActiveDevice && player.displayDurationMs > 0 }
    private var motorRequest: RecordMotorRequest {
        .resolve(phase: player.state.phase, ready: player.isEngineReady, active: player.state.isActiveDevice,
                 visible: presentation.isVisible, reduced: reduceMotion, pressed: pressedAngle != nil,
                 loadingFromPlaying: loadingFromPlaying)
    }
    private var isMoving: Bool {
        motorRequest != .snap && (motorRequest == .drive || isCoasting) && rotation.isMoving(at: ProcessInfo.processInfo.systemUptime)
    }
    private var isEngaged: Bool { presentation.mode != .compact }
    private var lyrics: LyricRibbonModel? { lyricModel ?? environment?.liveLyricRibbon?.model }
    private var showsLyrics: Bool { lyrics?.isVisible == true }
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
    private var image: Image? {
        if loadedArtworkRequest?.sessionRevision == artworkStore.sessionRevision, let loadedArtwork {
            return Image(nsImage: loadedArtwork.image)
        }
        return track?.artwork.flatMap {
            artworkStore.image(for: $0.url) ?? artworkStore.image(for: $0.url, pixelSize: 160)
        }.map { Image(nsImage: $0) }
    }
    private var backgroundImage: Image? {
        guard showsArtworkBackground, track?.artwork != nil else { return nil }
        // Keep the last cover's colors while the next cover loads, without retaining artwork across sign-outs.
        if loadedArtworkRequest?.sessionRevision == artworkStore.sessionRevision, let loadedArtwork {
            return Image(nsImage: loadedArtwork.image)
        }
        return image
    }
    private struct PressingRequest: Equatable {
        let uri: String?
        let artworkURL: URL?
        let retryRevision: Int
        let sessionRevision: Int
    }
    private var pressingRequest: PressingRequest {
        PressingRequest(uri: player.state.mirror?.trackURI.rawValue ?? track?.uri.rawValue ?? player.state.queue?.current?.uri?.rawValue,
                        artworkURL: track?.artwork?.url, retryRevision: artworkStore.retryRevision,
                        sessionRevision: artworkStore.sessionRevision)
    }
    private var recordStatus: Text {
        if let connectionStatus, connectionStatus.isVisible { return connectionStatus.message }
        if let notice = player.commandNotice { return Text(notice) }
        return player.state.localizedStatusText
    }
    private var connectionStatus: PlaybackConnectionStatusView? {
        guard let environment else { return nil }
        return PlaybackConnectionStatusView(status: environment.connectionStatus, restorationUnavailable: player.restorationUnavailable,
            hasConnected: environment.hasPlaybackConnected,
            onRetry: environment.retryPlaybackConnection, onReconnect: { Task { await environment.reconnectSpotify() } },
            isAuthorizing: environment.isAuthorizingPlayback, onCancel: environment.cancelPlaybackAuthorization)
    }
    private var needsAttention: Bool {
        if let connectionStatus, connectionStatus.isVisible { return false }
        if case .error = player.state.phase { return true }
        return player.commandNotice != nil
    }

    private var playerContent: some View {
        let layout = windowController.layout
        let previous: (() -> Void)? = player.isEngineReady && player.state.isActiveDevice && player.state.canPrevious ? { player.previous() } : nil
        let next: (() -> Void)? = player.isEngineReady && player.state.isActiveDevice && player.state.canNext ? { player.next() } : nil
        return ZStack(alignment: .topLeading) {
            PlayerSurface(cornerRadius: layout.sleeveCornerRadius, artwork: backgroundImage) {
                PlayerBackgroundDragRegion(takesKeyboardFocus: isEngaged, onDragChanged: dragLyrics)
            }
                .clipShape(RoundedRectangle(cornerRadius: layout.sleeveCornerRadius, style: .continuous))
                .frame(width: layout.sleeveFrame.width, height: layout.sleeveFrame.height)
                .offset(x: layout.sleeveFrame.minX, y: layout.sleeveFrame.minY)
                .opacity(isEngaged || showsLyrics ? 1 : 0)
                // Appears instantly hidden behind the record; on collapse it fades only once mostly folded back into it.
                .animation(isEngaged || reduceMotion ? nil : .easeIn(duration: 0.12).delay(lyrics?.isVisible == true ? 0 : 0.3), value: isEngaged)
                .allowsHitTesting(isEngaged || showsLyrics)
            ScrollView(layout.controlsFrame.width < 192 ? [.horizontal, .vertical] : .vertical) {
                // The scroll view swallows clicks on blank space, so the drag region must live inside it.
                controls.frame(minWidth: 192)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { controlsContentHeight = $0 }
                    .frame(minHeight: layout.controlsFrame.height, alignment: .top)
                    .background(PlayerBackgroundDragRegion())
            }
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize, axes: [.horizontal, .vertical])
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
                             coverBleed: layout.lowerFrame.minX - layout.sleeveFrame.minX, onPlay: loadFromShelf)
                    .frame(width: layout.lowerFrame.width, height: layout.lowerFrame.maxY - top)
                    .clipped()
                    .offset(x: layout.lowerFrame.minX, y: top)
                    .opacity(presentation.mode == .expanded ? 1 : 0)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: presentation.mode)
                    .allowsHitTesting(presentation.mode == .expanded)
                    .accessibilityHidden(presentation.mode != .expanded)
                    .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : 18))
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.16)))
            }
            QueueView(player: player, artworkStore: artworkStore, onSelect: select)
                .frame(width: layout.lowerFrame.width, height: layout.lowerFrame.height)
                .offset(x: layout.lowerFrame.minX, y: layout.lowerFrame.minY)
                .opacity(presentation.mode == .queue ? 1 : 0)
                .allowsHitTesting(presentation.mode == .queue)
                .disabled(presentation.mode != .queue)
                .accessibilityHidden(presentation.mode != .queue)
            if let lyrics, lyrics.isVisible, !layout.lyricsFrame.isEmpty {
                LyricPanelView(model: lyrics,
                    layout: LyricRibbonLayout(panelSize: layout.lyricsFrame.size,
                        textViewportHeight: max(1, layout.lyricsFrame.height - 2 * LyricRibbonLayout.verticalInset - 20
                            - (layout.controlsFrame.isEmpty ? LyricRibbonLayout.headerHeight + LyricRibbonLayout.sectionSpacing : 0)),
                        textScale: 1),
                    isCompact: layout.controlsFrame.isEmpty, onFocusReader: windowController.focusLyrics,
                    onSeek: { time, snapshot in
                        if let onLyricSeek { onLyricSeek(time, snapshot) }
                        else { environment?.liveLyricRibbon?.seek(to: time, from: snapshot) }
                    }, onPrevious: previous, onNext: next,
                    onPrepareDrag: { windowController.finishTransition(windowController.transitionID) },
                    onDragChanged: dragLyrics)
                    .overlay(alignment: .top) {
                        Rectangle().fill(.primary.opacity(0.14)).frame(height: 0.5)
                            .padding(.horizontal, LyricRibbonLayout.horizontalInset)
                            .opacity(isEngaged ? 1 : 0)
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isEngaged)
                            .allowsHitTesting(false)
                    }
                    .frame(width: layout.lyricsFrame.width, height: layout.lyricsFrame.height)
                    .offset(x: layout.lyricsFrame.minX, y: layout.lyricsFrame.minY)
                    .transition(.opacity.animation(reduceMotion ? nil : .easeOut(duration: 0.18)))
                    .onAppear { windowController.configureLyricsKeyboard(model: lyrics) }
            }
            if showsLyrics, !layout.lyricsFrame.isEmpty {
                let compact = layout.controlsFrame.isEmpty
                let scale: CGFloat = compact ? 0.75 : 1
                let width = compact ? max(1, layout.lyricsFrame.width - (player.state.mirror == nil ? 124 : 88))
                    : max(1, layout.controlsFrame.width - (player.state.mirror == nil ? 32 : 0))
                PlayerTrackMetadata(track: track, player: player, artworkStore: artworkStore, presentation: presentation)
                    .frame(width: width / scale, alignment: .leading)
                    .scaleEffect(scale, anchor: .topLeading)
                    .offset(x: compact ? layout.lyricsFrame.minX + 66 : layout.controlsFrame.minX,
                            y: compact ? layout.lyricsFrame.minY + 8 : layout.controlsFrame.minY)
                    .allowsHitTesting(!compact)
                    .transition(.identity)
                if compact, player.state.mirror == nil {
                    FavoriteButton()
                        .disabled(track?.uri != player.state.currentTrack?.uri)
                        .frame(width: 28, height: 28)
                        .offset(x: layout.lyricsFrame.maxX - LyricRibbonLayout.horizontalInset - 28,
                                y: layout.lyricsFrame.minY + LyricRibbonLayout.verticalInset)
                }
            }
        }
        .frame(width: layout.contentSize.width, height: layout.contentSize.height, alignment: .topLeading)
        .mask(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: layout.sleeveCornerRadius, style: .continuous)
                .frame(width: layout.sleeveFrame.width, height: layout.sleeveFrame.height)
                .offset(x: layout.sleeveFrame.minX, y: layout.sleeveFrame.minY)
        }
        .overlay(alignment: .topLeading) { recordStage(layout: layout) }
        .coordinateSpace(name: CoverFlowLaunch.coordinateSpace)
        .offset(x: windowController.contentOffset.x, y: windowController.contentOffset.y)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var playbackContent: some View {
        playerContent
        .onAppear { windowController.onCancelInteraction = cancelRecord }
        .onDisappear {
            finishCoverLoad()
            _ = cancelRecord(); setMotor(.snap); windowController.onCancelInteraction = nil
            windowController.removeLyricsKeyboard()
        }
        .task(id: coverTiming?.readyAt == nil ? coverLaunch?.id : nil) {
            guard let id = coverLaunch?.id, coverTiming?.readyAt == nil else { return }
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            guard coverLaunch?.id == id, coverTiming?.readyAt == nil else { return }
            finishCoverLoad()
            BopifyLog.playback.debug("cover preview ended while waiting for metadata")
        }
        .task(id: coverTiming?.finishedAt) {
            await finishReveal()
        }
        .onChange(of: player.playbackRevision) { _, _ in confirmCoverArtwork() }
        .onChange(of: player.recoveryIdentity) { _, _ in confirmCoverArtwork() }
        .onChange(of: player.engineEpoch) { _, _ in finishCoverLoad() }
        .onChange(of: player.isEngineReady) { _, ready in if !ready { finishCoverLoad() } }
        .onChange(of: player.isRunning) { _, running in if !running { finishCoverLoad() } }
        .onChange(of: windowController.layout) { _, _ in showsCoverFunnel = false }
        .onChange(of: artworkStore.sessionRevision) { _, _ in
            finishCoverLoad(); dockedCoverRatio = 0.43; loadingFromPlaying = false
            displayedPressing = PressingAppearance(seed: 0, palette: .neutral, design: designSelection.appearance,
                                                   recordDesign: recordDesignSelection.appearance)
            displayedOccurrenceID = "missing"; artworkRotationOffset = 0
        }
        .onChange(of: reduceMotion) { _, reduced in if reduced { finishCoverLoad() } }
        .onChange(of: player.commandFailureRevision) { _, _ in finishCoverLoad() }
        .onChange(of: player.state.phase) { _, phase in
            if phase != .loading { loadingFromPlaying = false }
            if case .error = phase { finishCoverLoad() }
            confirmCoverArtwork()
        }
        .onChange(of: showsLyrics) { _, visible in
            if !visible { windowController.removeLyricsKeyboard() }
        }
        .onChange(of: motorRequest, initial: true) { _, request in setMotor(request) }
        .task(id: rotation.stopTime) {
            await finishCoasting()
        }
    }

    var body: some View {
        playbackContent
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
            if mode != .expanded { showsCoverFunnel = false }
        }
        .onChange(of: presentation.isVisible) { _, visible in
            if !visible { loadingFromPlaying = false; finishCoverLoad(); pendingSelection = nil; accessibilityFocus = false; isRecordHovered = false; _ = cancelRecord() }
        }
        .onChange(of: accessibilityFocus) { _, focused in presentation.sendAttention(.accessibilityFocus(focused)) }
        .task(id: pressingRequest) { await loadPressing() }
        .onChange(of: designRawValue, initial: true) { _, value in
            designSelection.select(rawValue: value)
            applySelectedDesign()
        }
        .onChange(of: recordDesignRawValue, initial: true) { _, value in
            recordDesignSelection.select(rawValue: value)
            applySelectedDesign()
        }
    }

    private func finishReveal() async {
        guard let deadline = coverTiming?.finishedAt, let id = coverLaunch?.id else { return }
        do { try await Task.sleep(until: deadline, clock: SuspendingClock()) } catch { return }
        guard !Task.isCancelled, coverLaunch?.id == id, coverTiming?.finishedAt == deadline else { return }
        finishCoverLoad()
        BopifyLog.playback.debug("cover load reveal finished")
    }

    private func finishCoasting() async {
        guard isCoasting, let deadline = rotation.stopTime else { return }
        let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        do { try await Task.sleep(for: .seconds(remaining), clock: SuspendingClock()) } catch { return }
        guard !Task.isCancelled, rotation.stopTime == deadline else { return }
        isCoasting = false
    }

    private func recordStage(layout: RecordLayout) -> some View {
        ZStack(alignment: .topLeading) {
            if let outgoingRecord {
                VinylRecordView(image: outgoingRecord.image, occurrenceID: outgoingRecord.occurrenceID,
                    direction: .fade, diameter: layout.recordDiameter, isMoving: isMoving,
                    isVisible: presentation.isVisible, rotation: rotation,
                    pressingSeed: outgoingRecord.pressing.seed, palette: outgoingRecord.pressing.palette,
                    design: outgoingRecord.pressing.design,
                    recordDesign: outgoingRecord.pressing.recordDesign,
                    artworkRotationOffset: outgoingRecord.artworkRotationOffset,
                    rotationOverride: pressedAngle.map { $0 + (scrub?.angleDelta ?? 0) },
                    isScrubbing: pressedAngle != nil, reduceMotionOverride: reduceMotion,
                    labelRatio: outgoingRecord.labelRatio)
                    .position(layout.recordCenter)
                    .allowsHitTesting(false)
            }
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: coverLaunch == nil)) { _ in
                let progress = coverLaunch == nil ? 1 : coverTiming?.progress(at: SuspendingClock.now) ?? 0
                let angle = pressedAngle.map { $0 + (scrub?.angleDelta ?? 0) }
                    ?? rotation.angle(at: ProcessInfo.processInfo.systemUptime)
                ZStack(alignment: .topLeading) {
                    recordFace(diameter: layout.recordDiameter, loadProgress: progress,
                               angle: coverLaunch == nil ? nil : angle).position(layout.recordCenter)
                    if showsCoverFunnel, let launch = coverLaunch {
                        RecordLoadTransition(launch: launch,
                            destination: CGRect(x: layout.recordCenter.x - layout.recordDiameter / 2,
                                                y: layout.recordCenter.y - layout.recordDiameter / 2,
                                                width: layout.recordDiameter, height: layout.recordDiameter),
                            progress: progress, reduceMotion: reduceMotion,
                            rotationAngle: angle + coverRotationOffset)
                    }
                }
            }
            recordControls(diameter: layout.recordDiameter).position(layout.recordCenter)
        }
        .frame(width: layout.contentSize.width, height: layout.contentSize.height, alignment: .topLeading)
    }

    private func loadPressing() async {
        let request = pressingRequest
        let artwork: LoadedArtwork?
        if loadedArtworkRequest?.url == request.artworkURL,
           loadedArtworkRequest?.sessionRevision == request.sessionRevision, let loadedArtwork {
            artwork = loadedArtwork
        } else if let url = request.artworkURL {
            artwork = await artworkStore.loadPalette(url)
        } else {
            artwork = nil
        }
        guard !Task.isCancelled, request == pressingRequest else { return }
        loadedArtwork = artwork
        loadedArtworkRequest = ArtworkLoadRequest(url: request.artworkURL, retryRevision: request.retryRevision,
                                                 sessionRevision: request.sessionRevision)
        displayedOccurrenceID = occurrenceID
        displayedPressing = PressingAppearance(seed: request.uri.map(PressingSeed.offset) ?? 0,
                                               palette: artwork?.palette ?? .neutral, design: designSelection.appearance,
                                               recordDesign: recordDesignSelection.appearance)
        confirmCoverArtwork()
    }

    private func loadFromShelf(_ request: PlayRequest, launch: CoverFlowLaunch) {
        let revealed = coverTiming.map { RecordLoadStage(progress: $0.progress(at: SuspendingClock.now)).incomingOpacity >= 0.5 } ?? true
        // Settle an already revealed song before replacing it; an abandoned flight never becomes the baseline.
        let previous = (!revealed ? outgoingRecord : nil) ?? OutgoingRecordAppearance(image: image, occurrenceID: displayedOccurrenceID,
            labelRatio: dockedCoverRatio, pressing: displayedPressing, artworkRotationOffset: artworkRotationOffset)
        loadingFromPlaying = appliedMotorRequest == .drive
        coverStartRevision = player.playbackRevision
        coverEngineEpoch = player.engineEpoch
        player.load(request)
        guard player.isEngineReady, player.isRunning, presentation.isVisible, presentation.mode == .expanded,
              !reduceMotion, launch.sourceFrame.width > 0, launch.artwork != nil else { finishCoverLoad(); return }
        coverLaunch = launch
        designSelection.beginHandoff()
        recordDesignSelection.beginHandoff()
        showsCoverFunnel = true
        outgoingRecord = previous
        coverTiming = RecordLoadTiming(startedAt: launch.startedAt)
        let angle = rotation.angle(at: ProcessInfo.processInfo.systemUptime)
        coverRotationOffset = -angle
        artworkRotationOffset = coverRotationOffset
        dockedCoverRatio = launch.sourceFrame.width / windowController.layout.recordDiameter
        confirmCoverArtwork()
        BopifyLog.playback.debug("cover flight started")
    }

    private func confirmCoverArtwork() {
        guard let launch = coverLaunch, coverTiming?.readyAt == nil,
              player.engineEpoch == coverEngineEpoch, player.playbackRevision > coverStartRevision,
              player.state.phase == .playing || player.state.phase == .paused, let track,
              launch.itemURI.kind == .track ? track.uri == launch.itemURI
                : player.recoveryIdentity?.contextURI == launch.itemURI.rawValue && player.recoveryIdentity?.trackURI == track.uri,
              loadedArtworkRequest?.url == track.artwork?.url,
              loadedArtworkRequest?.sessionRevision == artworkStore.sessionRevision,
              track.artwork == nil || image != nil else { return }
        coverTiming?.confirm(at: SuspendingClock.now)
    }

    private func finishCoverLoad() {
        coverLaunch = nil
        coverTiming = nil
        outgoingRecord = nil
        showsCoverFunnel = false
        designSelection.finishHandoff()
        recordDesignSelection.finishHandoff()
        applySelectedDesign()
    }

    private func applySelectedDesign() {
        guard coverLaunch == nil else { return }
        displayedPressing.design = designSelection.appearance
        displayedPressing.recordDesign = recordDesignSelection.appearance
    }

    private func recordFace(diameter: CGFloat, loadProgress: Double, angle: Double?) -> some View {
        VinylRecordView(image: image, occurrenceID: displayedOccurrenceID, direction: coverLaunch == nil ? direction : .fade, diameter: diameter,
                        isMoving: isMoving && coverLaunch == nil,
                        isVisible: presentation.isVisible, rotation: rotation,
                        pressingSeed: displayedPressing.seed, palette: displayedPressing.palette,
                        design: displayedPressing.design,
                        recordDesign: displayedPressing.recordDesign,
                        artworkRotationOffset: artworkRotationOffset,
                        rotationOverride: angle ?? pressedAngle.map { $0 + (scrub?.angleDelta ?? 0) }, isScrubbing: pressedAngle != nil,
                        reduceMotionOverride: reduceMotion, loadProgress: loadProgress,
                        labelRatio: dockedCoverRatio,
                        isIncomingDuringLoad: coverLaunch != nil)
    }

    private func recordControls(diameter: CGFloat) -> some View {
        Color.clear.frame(width: diameter, height: diameter)
            .overlay {
                if showsLyrics && !isEngaged {
                    PlayerBackgroundDragRegion(takesKeyboardFocus: false,
                        onPrepareDrag: { windowController.finishTransition(windowController.transitionID) },
                        onDragChanged: windowController.setDragging, onClick: windowController.focus)
                        .clipShape(Circle())
                        .help("Click to open the player. Drag to move.")
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text("Open player"))
                        .accessibilityValue(recordStatus)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { windowController.focus() }
                } else {
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
                            if !hasScrubbed {
                                hasScrubbed = true
                            }
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
                    .onHover { isRecordHovered = $0 }
                    .help(canScrub && !hasScrubbed ? String(localized: "record.scrub.help") : "")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(track?.title ?? String(localized: "player.unknownTrack")))
                    .accessibilityValue(recordStatus)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { windowController.focus() }
                    .accessibilityFocused($accessibilityFocus)
                }
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
                if canScrub, isEngaged, isScrubbing || (isRecordHovered && !hasScrubbed) {
                    Group {
                        if isScrubbing, let scrub {
                            Text(verbatim: "\(playbackTime(scrub.positionMs)) / \(playbackTime(player.displayDurationMs))")
                                .monospacedDigit()
                        } else {
                            Label("record.scrub.hint", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.black.opacity(0.8), in: Capsule())
                    .padding(.bottom, 18)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .bottom) {
                if !isEngaged && !showsLyrics, let connectionStatus, connectionStatus.isVisible {
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

    private func dragLyrics(_ active: Bool) {
        windowController.setDragging(active)
        if isEngaged || !active { presentation.sendAttention(.interaction(.windowDrag, active)) }
    }


    private var controls: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 4) {
                if showsLyrics, !windowController.layout.lyricsFrame.isEmpty {
                    Color.clear.frame(height: 42).frame(maxWidth: .infinity).accessibilityHidden(true)
                } else {
                    PlayerTrackMetadata(track: track, player: player, artworkStore: artworkStore, presentation: presentation)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Hidden while mirroring: Bopify still has its own track, and the heart would show that track's saved state.
                if player.state.mirror == nil {
                    FavoriteButton()
                        .disabled(track?.uri != player.state.currentTrack?.uri)
                }
            }
            .modifier(UnfurlRow(index: 0, isEngaged: isEngaged, reduceMotion: reduceMotion, showsLyrics: lyrics?.isVisible == true))
            TransportControls(player: player)
                .frame(maxWidth: .infinity)
                .modifier(UnfurlRow(index: 1, isEngaged: isEngaged, reduceMotion: reduceMotion, showsLyrics: lyrics?.isVisible == true))
            TimelineView(PlaybackClockSchedule(isRunning: player.isPositionAdvancing && presentation.isVisible, reduceMotion: true)) { context in
                HStack {
                    Text(playbackTime(isScrubbing ? (scrub?.positionMs ?? 0) : player.displayPositionMs(at: context.date)))
                    Spacer()
                    Text(playbackTime(player.displayDurationMs))
                }.font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            }
            .modifier(UnfurlRow(index: 2, isEngaged: isEngaged, reduceMotion: reduceMotion, showsLyrics: lyrics?.isVisible == true))
            HStack(spacing: 4) {
                if let environment {
                    Button {
                        if let lyricModel {
                            if lyricModel.isVisible { lyricModel.hide() } else { lyricModel.show() }
                        } else { environment.toggleLiveLyrics() }
                    } label: {
                        Image(.bopLyrics).frame(width: 28, height: 28)
                    }.buttonStyle(.playerToggle(isOn: lyrics?.isVisible ?? false))
                        .accessibilityLabel(String(localized: "control.title", defaultValue: "Lyrics", table: "LyricRibbon"))
                        .accessibilityValue(Text(lyrics?.isVisible == true ? "control.on" : "control.off"))
                        .help(String(localized: "control.help", defaultValue: "Show or hide lyrics", table: "LyricRibbon"))
                        .contextMenu {
                            Button(String(localized: "menu.focus", table: "LyricRibbon")) { environment.focusLiveLyrics() }
                        }
                        .disabled(environment.isPreparingForQuit || environment.authState != .signedIn)
                }
                Button { presentation.requestQueue(presentation.mode != .queue) } label: {
                    Image(.bopQueue).frame(width: 28, height: 28)
                }.buttonStyle(.playerToggle(isOn: presentation.mode == .queue))
                    .accessibilityLabel(Text("queue.title"))
                    .accessibilityValue(Text(presentation.mode == .queue ? "control.on" : "control.off"))
                    .help(Text("queue.title"))
                    .disabled(player.state.mirror != nil && presentation.mode != .queue)
                VolumeControl(player: player, presentation: presentation)
                if let environment {
                    SearchButton(environment: environment)
                }
            }
            .frame(maxWidth: .infinity)
            .modifier(UnfurlRow(index: 3, isEngaged: isEngaged, reduceMotion: reduceMotion, showsLyrics: lyrics?.isVisible == true))
            // The status keeps its line while empty so the library tabs below don't jump each time a track loads.
            ZStack(alignment: .leading) {
                Text(verbatim: " ").hidden()
                status
            }
                .frame(maxWidth: .infinity, alignment: .leading)
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .modifier(UnfurlRow(index: 4, isEngaged: isEngaged, reduceMotion: reduceMotion, showsLyrics: lyrics?.isVisible == true))
        }
        .buttonStyle(.playerControl)
        .onDisappear { presentation.sendAttention(.interaction(.volume, false)) }
    }

    @ViewBuilder private var status: some View {
        if let connectionStatus, connectionStatus.isVisible { connectionStatus }
        else if let notice = player.commandNotice { Text(notice) }
        else {
            switch player.state.phase {
            case .loading:
                HStack(spacing: 5) { ProgressView().controlSize(.mini); Text("player.loading") }
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

struct PlayerTrackMetadata: View {
    let track: Track?
    let player: PlayerModel
    let artworkStore: ArtworkStore
    let presentation: PlayerPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(track?.title ?? String(localized: "player.unknownTrack"))
                .font(.system(size: 17, weight: .medium)).lineLimit(1).help(track?.title ?? "")
                .frame(height: 21, alignment: .leading)
            Group {
                if let track {
                    ArtistSongsButton(track: track, player: player, artworkStore: artworkStore, presentation: presentation)
                } else {
                    Color.clear.accessibilityHidden(true)
                }
            }
            .frame(height: 18)
        }
    }
}

/// Cascades a control row in after the sleeve starts unfurling; all rows leave together so a quick flick never strands one.
private struct UnfurlRow: ViewModifier {
    let index: Int
    let isEngaged: Bool
    let reduceMotion: Bool
    let showsLyrics: Bool
    func body(content: Content) -> some View {
        let settled = isEngaged || reduceMotion
        content
            .opacity(isEngaged ? 1 : 0)
            .blur(radius: settled ? 0 : 6)
            .offset(x: settled ? 0 : -14, y: !settled && showsLyrics ? 18 : 0)
            .animation(reduceMotion ? nil : isEngaged ? .spring(duration: showsLyrics ? 0.20 : 0.4, bounce: showsLyrics ? 0 : 0.1)
                .delay(showsLyrics ? Double(index) * 0.02 : 0.12 + Double(index) * 0.04)
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
