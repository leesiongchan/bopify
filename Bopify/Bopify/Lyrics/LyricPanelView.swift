import AppKit
import BopifyPlayback
import SwiftUI

struct LyricPanelView: View {
    let model: LyricRibbonModel
    let layout: LyricRibbonLayout
    var isCompact = false
    var onFocusReader: () -> Void = {}
    var onSeek: (Int64, LyricPlaybackSnapshot) -> Void = { _, _ in }
    var onPrevious: (() -> Void)? = nil
    var onNext: (() -> Void)? = nil
    var onPrepareDrag: () -> Void = {}
    var onDragChanged: (Bool) -> Void = { _ in }
    @FocusState private var syncFocused: Bool
    @State private var syncFrame: CGRect = .zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            .font: NSFont.systemFont(ofSize: 15 * layout.textScale), .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }

    var body: some View {
        sleeve
        .frame(width: layout.panelSize.width, height: layout.panelSize.height, alignment: .topLeading)
        .overlay {
            LyricPanelDragOverlay(excludedFrame: model.isReading ? syncFrame : .zero,
                onPrepareDrag: onPrepareDrag, onDragChanged: onDragChanged)
        }
        .overlay(alignment: .bottomLeading) {
            if let attribution = model.source?.attribution {
                Text(attribution).font(.system(size: 9)).foregroundStyle(.secondary)
                    .opacity(0.6).lineLimit(1).help(attribution)
                    .padding(.trailing, model.isReading ? 44 : 0)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, LyricRibbonLayout.horizontalInset)
                    .padding(.bottom, LyricRibbonLayout.verticalInset)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if model.isReading {
                syncControl.fixedSize()
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("lyricPanelSurface")) } action: { syncFrame = $0 }
                    .padding(.trailing, LyricRibbonLayout.horizontalInset)
                    .padding(.bottom, LyricRibbonLayout.verticalInset)
            }
        }
        .coordinateSpace(name: "lyricPanelSurface")
        .onChange(of: model.keyboardSelection) { _, selection in
            syncFocused = selection == .sync
            if selection == .reader { onFocusReader() }
        }
    }

    private var sleeve: some View {
        ZStack {
            VStack(spacing: LyricRibbonLayout.sectionSpacing) {
                if isCompact {
                    Color.clear.frame(height: LyricRibbonLayout.headerHeight).accessibilityHidden(true)
                }
                LyricPassageView(text: message, content: model.content, projection: model.projection,
                    isReading: model.isReading, textScale: layout.textScale, isRightToLeft: model.source?.isRightToLeft ?? false,
                    width: max(1, layout.panelSize.width - 2 * LyricRibbonLayout.horizontalInset),
                    height: layout.textViewportHeight, resetRevision: model.scrollResetRevision,
                    animate: !reduceMotion, onBeginReading: model.beginReading,
                    shouldFocusReader: { model.isKeyboardInteracting && model.keyboardSelection == .reader },
                    occurrenceID: model.snapshot.occurrenceID, direction: model.snapshot.direction,
                    onSeek: { [snapshot = model.snapshot] time in onSeek(time, snapshot) },
                    onPrevious: isCompact ? onPrevious : nil, onNext: isCompact ? onNext : nil)
                    .frame(height: layout.textViewportHeight)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: model.snapshot.occurrenceID)
        .padding(.horizontal, LyricRibbonLayout.horizontalInset)
        .padding(.vertical, LyricRibbonLayout.verticalInset)
        .frame(width: layout.panelSize.width,
               height: layout.panelSize.height, alignment: .top)
    }

    private var syncControl: some View { syncButton.buttonStyle(.glass) }
    private var syncButton: some View {
        Button(action: model.backToLive) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 13, weight: .medium)).foregroundStyle(.primary)
                .frame(width: 20, height: 20)
        }
        .controlSize(.small)
        .accessibilityLabel(String(localized: "action.sync", defaultValue: "Sync", table: "LyricRibbon"))
        .buttonBorderShape(.circle)
        .help(String(localized: "action.sync.help", defaultValue: "Return to the current lyric without changing playback", table: "LyricRibbon"))
        .focusable(interactions: [.edit, .activate])
        .focused($syncFocused)
    }
}

private struct LyricPanelDragOverlay: NSViewRepresentable {
    let excludedFrame: CGRect
    let onPrepareDrag: () -> Void
    let onDragChanged: (Bool) -> Void

    func makeNSView(context: Context) -> SurfaceDragView { SurfaceDragView() }
    func updateNSView(_ view: SurfaceDragView, context: Context) {
        view.takesKeyboardFocus = false
        view.onPrepareDrag = onPrepareDrag
        view.onDragChanged = onDragChanged
        view.excludedFrame = excludedFrame
    }

    final class SurfaceDragView: PlayerBackgroundDragRegion.DragView {
        var excludedFrame: CGRect = .zero
        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard super.hitTest(point) != nil else { return nil }
            let local = convert(point, from: superview)
            if excludedFrame.contains(local) { return nil }
            if let reader = reader(in: window?.contentView), let scroll = reader.enclosingScrollView {
                let location = scroll.convert(local, from: self)
                if scroll.bounds.contains(location) {
                    if scroll.hasVerticalScroller, let scroller = scroll.verticalScroller,
                       scroller.hitTest(convert(local, to: scroller.superview)) != nil { return nil }
                    if reader.visibleCharacter(at: reader.convert(local, from: self)) != nil { return nil }
                }
            }
            return self
        }

        override func scrollWheel(with event: NSEvent) {
            if let scroll = reader(in: window?.contentView)?.enclosingScrollView {
                scroll.scrollWheel(with: event)
            } else { super.scrollWheel(with: event) }
        }

        private func reader(in view: NSView?) -> LyricReadingTextView? {
            guard let view else { return nil }
            if let reader = view as? LyricReadingTextView { return reader }
            return view.subviews.lazy.compactMap { self.reader(in: $0) }.first
        }
    }
}

#if DEBUG
private func previewLyricPanel(_ kind: String) -> some View {
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
    let layout = LyricRibbonLayout.measure(width: 448, textScale: 1, availableHeight: 320)
    return LyricPanelView(model: model, layout: layout)
}

#Preview("Live lyrics") { previewLyricPanel("live") }
#Preview("Reading lyrics") { previewLyricPanel("reading") }
#Preview("Long lyrics") { previewLyricPanel("long") }
#Preview("Plain lyrics") { previewLyricPanel("plain") }
#Preview("Unavailable lyrics") { previewLyricPanel("unavailable") }
#Preview("Right-to-left lyrics") { previewLyricPanel("rtl") }
#endif
