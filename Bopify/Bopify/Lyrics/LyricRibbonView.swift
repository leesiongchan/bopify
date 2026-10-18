import AppKit
import SwiftUI
import BopifyPlayback
import BopifyDomain
import os

struct LyricRibbonView: View {
    let model: LyricRibbonModel
    let layout: LyricRibbonLayout
    var artworkStore: ArtworkStore? = nil
    var onFocusReader: () -> Void = {}
    var onSeek: (Int64, LyricPlaybackSnapshot) -> Void = { _, _ in }
    let onDragHeader: (NSEvent) -> Void
    @FocusState private var syncFocused: Bool
    @State private var rotation = RecordRotation()
    @State private var isCoasting = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var palette: ArtworkPalette {
        model.snapshot.artworkURL.flatMap { artworkStore?.palette(for: $0) } ?? .neutral
    }
    private var accent: Color {
        let color: ArtworkColor = switch palette { case let .marble(a, _, _): a; case let .tinted(a): a }
        return Color(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: 1)
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
            VinylRecordView(image: model.snapshot.artworkURL.flatMap { artworkStore?.image(for: $0) }.map { Image(nsImage: $0) },
                occurrenceID: model.snapshot.occurrenceID, direction: model.snapshot.direction, diameter: 96,
                isMoving: motorRequest == .drive || isCoasting, isVisible: model.isVisible, rotation: rotation,
                pressingSeed: PressingSeed.offset(model.snapshot.recordingID), palette: palette,
                reduceMotionOverride: reduceMotion)
                .offset(y: max(0, (layout.panelSize.height - 96) / 2))
                .allowsHitTesting(false).accessibilityHidden(true)
            sleeve.padding(.leading, LyricRibbonLayout.sleeveInset)
        }
        .frame(width: layout.panelSize.width, height: layout.panelSize.height)
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
                    .overlay { LyricHeaderDrag(onDrag: onDragHeader) }
                    .id(model.snapshot.occurrenceID).transition(trackTransition)
                    if model.isReading { syncControl.fixedSize() }
                }
                .frame(height: LyricRibbonLayout.headerHeight, alignment: .leading)
                LyricPassageView(text: message, content: model.content, projection: model.projection,
                    isReading: model.isReading, textScale: layout.textScale, isRightToLeft: model.source?.isRightToLeft ?? false,
                    width: max(1, layout.panelSize.width - LyricRibbonLayout.sleeveInset - 2 * LyricRibbonLayout.horizontalInset),
                    height: layout.textViewportHeight, resetRevision: model.scrollResetRevision,
                    animate: !reduceMotion, onBeginReading: model.beginReading,
                    shouldFocusReader: { model.isKeyboardInteracting && model.keyboardSelection == .reader },
                    occurrenceID: model.snapshot.occurrenceID, direction: model.snapshot.direction,
                    onSeek: { [snapshot = model.snapshot] time in onSeek(time, snapshot) })
                    .frame(height: layout.textViewportHeight)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: model.snapshot.occurrenceID)
        .padding(.horizontal, LyricRibbonLayout.horizontalInset)
        .padding(.vertical, LyricRibbonLayout.verticalInset)
        .frame(width: max(1, layout.panelSize.width - LyricRibbonLayout.sleeveInset), height: layout.panelSize.height)
        .background {
            let shape = UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10,
                                                bottomTrailingRadius: 20, topTrailingRadius: 20)
            if reduceTransparency || contrast == .increased { shape.fill(Color(nsColor: .windowBackgroundColor)) }
            else {
                shape.fill(LinearGradient(colors: [Color(red: 0.19, green: 0.22, blue: 0.16),
                    Color(red: 0.12, green: 0.15, blue: 0.115), Color(red: 0.10, green: 0.13, blue: 0.10)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        }
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(LinearGradient(colors: [accent.opacity(0.65), Color.black.opacity(0.45), accent.opacity(0.25)],
                    startPoint: .leading, endPoint: .trailing))
                .frame(width: 3).padding(.vertical, 5)
                .shadow(color: .black.opacity(0.35), radius: 2, x: -1)
                .allowsHitTesting(false)
        }
        .overlay {
            UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10,
                                   bottomTrailingRadius: 20, topTrailingRadius: 20)
                .strokeBorder(.white.opacity(contrast == .increased ? 0.5 : 0.12), lineWidth: 1).allowsHitTesting(false)
        }
    }

    @ViewBuilder private var syncControl: some View {
        if reduceTransparency || contrast == .increased { syncButton.buttonStyle(.bordered) }
        else { syncButton.buttonStyle(.glass) }
    }
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

private struct LyricHeaderDrag: NSViewRepresentable {
    let onDrag: (NSEvent) -> Void
    final class DragView: NSView {
        var onDrag: ((NSEvent) -> Void)?
        override func mouseDown(with event: NSEvent) { onDrag?(event) }
    }
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) { view.onDrag = onDrag }
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
    return LyricRibbonView(model: model, layout: layout, onDragHeader: { _ in })
}

#Preview("Live lyrics") { previewLyricRibbon("live") }
#Preview("Reading lyrics") { previewLyricRibbon("reading") }
#Preview("Long lyrics") { previewLyricRibbon("long") }
#Preview("Plain lyrics") { previewLyricRibbon("plain") }
#Preview("Unavailable lyrics") { previewLyricRibbon("unavailable") }
#Preview("Right-to-left lyrics") { previewLyricRibbon("rtl") }
#endif
