import AppKit
import SwiftUI
import BopifyPlayback
import BopifyDomain
import os
import Observation

@Observable final class LyricRibbonPosition {
    var offset: CGPoint = .zero
}

struct LyricRibbonView: View {
    let model: LyricRibbonModel
    let layout: LyricRibbonLayout
    var artworkStore: ArtworkStore? = nil
    var onFocusReader: () -> Void = {}
    var onSeek: (Int64, LyricPlaybackSnapshot) -> Void = { _, _ in }
    var position = LyricRibbonPosition()
    var onPrepareDrag: () -> Void = {}
    var onDragChanged: (Bool) -> Void = { _ in }
    @FocusState private var syncFocused: Bool
    @State private var rotation = RecordRotation()
    @State private var isCoasting = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var palette: ArtworkPalette {
        model.snapshot.artworkURL.flatMap { artworkStore?.palette(for: $0) } ?? .neutral
    }
    private var motorRequest: RecordMotorRequest {
        .resolve(phase: model.snapshot.isPlaying ? .playing : .paused, ready: true, active: true,
                 visible: model.isVisible, reduced: reduceMotion, pressed: false)
    }
    private var message: NSAttributedString {
        let value: String = switch model.content {
        case .loading: "Loading lyrics…"
        case .instrumental: "Instrumental"
        case .noMatch: "No lyrics found"
        case .failure: "Lyrics unavailable"
        case let .idle(reason): reason.message
        default: ""
        }
        return NSAttributedString(string: value, attributes: [
            .font: NSFont.systemFont(ofSize: 17 * layout.textScale), .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }
    private var trackTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let distance: CGFloat = switch model.snapshot.direction { case .next: 9; case .previous: -9; case .fade: 0 }
        return .asymmetric(insertion: .opacity.combined(with: .offset(x: distance)), removal: .opacity)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            dragRegion.frame(width: layout.panelSize.width, height: layout.panelSize.height)
            sleeve.padding(.leading, LyricRibbonLayout.sleeveInset).padding(.top, LyricRibbonLayout.surfaceInset)
            VinylRecordView(image: model.snapshot.artworkURL.flatMap { artworkStore?.image(for: $0) }.map { Image(nsImage: $0) },
                occurrenceID: model.snapshot.occurrenceID, direction: model.snapshot.direction, diameter: 96,
                isMoving: motorRequest == .drive || isCoasting, isVisible: model.isVisible, rotation: rotation,
                pressingSeed: PressingSeed.offset(model.snapshot.recordingID), palette: palette,
                reduceMotionOverride: reduceMotion)
                .offset(x: 8, y: max(0, (layout.panelSize.height - 96) / 2))
                .allowsHitTesting(false).accessibilityHidden(true)
        }
        .frame(width: layout.panelSize.width, height: layout.panelSize.height)
        .offset(x: position.offset.x, y: position.offset.y)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .preferredColorScheme(.dark)
        .onChange(of: model.keyboardSelection) { _, selection in
            syncFocused = selection == .sync
            if selection == .reader { onFocusReader() }
        }
        .task(id: ArtworkLoadRequest(url: model.snapshot.artworkURL, retryRevision: artworkStore?.retryRevision ?? 0)) {
            if let url = model.snapshot.artworkURL { await artworkStore?.loadPalette(url) }
        }
        .onChange(of: motorRequest, initial: true) { _, request in
            rotation.setRunning(request == .drive, at: ProcessInfo.processInfo.systemUptime,
                                stopStyle: request == .brake ? .brake : .snap)
            isCoasting = request == .brake && rotation.stopTime != nil
            BopifyLog.playback.debug("lyric vinyl motor=\(request.rawValue, privacy: .public)")
        }
        .task(id: rotation.stopTime) {
            guard isCoasting, let deadline = rotation.stopTime else { return }
            do { try await Task.sleep(for: .seconds(max(0, deadline - ProcessInfo.processInfo.systemUptime))) }
            catch { return }
            isCoasting = false
        }
    }

    private var sleeve: some View {
        ZStack {
            VStack(spacing: LyricRibbonLayout.sectionSpacing) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.snapshot.title).font(.system(size: 12, weight: .medium))
                        HStack(spacing: 5) {
                            if !model.snapshot.artist.isEmpty {
                                Text(model.snapshot.artist).lineLimit(1)
                            }
                            if let attribution = model.source?.attribution {
                                if !model.snapshot.artist.isEmpty { Text(verbatim: "·").accessibilityHidden(true) }
                                Text(attribution).lineLimit(1).layoutPriority(1).help(attribution)
                            }
                        }
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    .help("\(model.snapshot.title) · \(model.snapshot.artist)")
                    .overlay { dragRegion }
                    .id(model.snapshot.occurrenceID).transition(trackTransition)
                    if model.isReading { syncControl.fixedSize() }
                }
                .frame(height: LyricRibbonLayout.headerHeight, alignment: .leading)
                LyricPassageView(text: message, content: model.content, projection: model.projection,
                    isReading: model.isReading, textScale: layout.textScale, isRightToLeft: model.source?.isRightToLeft ?? false,
                    width: max(1, layout.panelSize.width - LyricRibbonLayout.sleeveInset - LyricRibbonLayout.readerInset
                        - LyricRibbonLayout.horizontalInset - LyricRibbonLayout.surfaceInset),
                    height: layout.textViewportHeight, resetRevision: model.scrollResetRevision,
                    animate: !reduceMotion, onBeginReading: model.beginReading,
                    shouldFocusReader: { model.isKeyboardInteracting && model.keyboardSelection == .reader },
                    occurrenceID: model.snapshot.occurrenceID, direction: model.snapshot.direction,
                    onSeek: { [snapshot = model.snapshot] time in onSeek(time, snapshot) })
                    .frame(height: layout.textViewportHeight)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: model.snapshot.occurrenceID)
        .padding(.leading, LyricRibbonLayout.readerInset)
        .padding(.trailing, LyricRibbonLayout.horizontalInset)
        .padding(.vertical, LyricRibbonLayout.verticalInset)
        .frame(width: max(1, layout.panelSize.width - LyricRibbonLayout.sleeveInset - LyricRibbonLayout.surfaceInset),
               height: max(1, layout.panelSize.height - 2 * LyricRibbonLayout.surfaceInset))
        .background {
            let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
            if reduceTransparency || contrast == .increased { shape.fill(Color(nsColor: .windowBackgroundColor)).allowsHitTesting(false) }
            else {
                Color.clear.glassEffect(.regular.tint(Color(red: 0.16, green: 0.20, blue: 0.14).opacity(0.65)), in: shape)
                    // The native text reader needs a stable dark field on bright desktops.
                    .overlay { shape.fill(Color(red: 0.08, green: 0.11, blue: 0.075).opacity(0.75)) }
                    .allowsHitTesting(false)
            }
        }
    }

    private var dragRegion: some View {
        PlayerBackgroundDragRegion(takesKeyboardFocus: false, onPrepareDrag: onPrepareDrag, onDragChanged: onDragChanged)
    }
    private var syncControl: some View { syncButton.buttonStyle(.bordered) }
    private var syncButton: some View {
        Button(action: model.backToLive) {
            Text(String(localized: "action.sync", defaultValue: "Sync", table: "LyricRibbon"))
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.primary).frame(minHeight: 22)
        }
        .controlSize(.small)
        .accessibilityLabel(String(localized: "action.sync", defaultValue: "Sync", table: "LyricRibbon"))
        .buttonBorderShape(.capsule)
        .help(String(localized: "action.sync.help", defaultValue: "Return to the current lyric without changing playback", table: "LyricRibbon"))
        .focusable(interactions: [.edit, .activate])
        .focused($syncFocused)
    }
}

#if DEBUG
private func previewLyricRibbon(_ kind: String) -> some View {
    let model = LyricRibbonModel(snapshot: LyricPlaybackSnapshot(sessionID: "preview", occurrenceID: "one",
        recordingID: "original", title: "Window Seat", artist: "Soft Weather", positionMs: 72_000,
        durationMs: 100_000, isPlaying: true, seekRevision: 0))
    let words = switch kind {
    case "long": String(repeating: "Leave a little room for the rain, and a little room for the light. ", count: 16)
    case "rtl": "للنافذة ضوء هادئ\nوللصباح متسع جديد"
    default: "Leave a little room for the rain"
    }
    let content: LyricContent = switch kind {
    case "plain": .plain(words)
    case "unavailable": .noMatch
    default: .timed(try! LyricDocument(cues: [LyricCue(id: "previous", startMs: 0, text: "The afternoon folds into green"),
        LyricCue(id: "current", startMs: 70_000, text: words)]))
    }
    model.show()
    model.completeLoad(content, token: model.beginLoad())
    if kind == "reading" { model.beginReading() }
    let layout = LyricRibbonLayout.measure(content: content, width: 448, textScale: 1, availableHeight: 320)
    return LyricRibbonView(model: model, layout: layout)
}

#Preview("Live lyrics") { previewLyricRibbon("live") }
#Preview("Reading lyrics") { previewLyricRibbon("reading") }
#Preview("Long lyrics") { previewLyricRibbon("long") }
#Preview("Plain lyrics") { previewLyricRibbon("plain") }
#Preview("Unavailable lyrics") { previewLyricRibbon("unavailable") }
#Preview("Right-to-left lyrics") { previewLyricRibbon("rtl") }
#endif
