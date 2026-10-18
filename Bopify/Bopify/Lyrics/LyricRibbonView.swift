import AppKit
import SwiftUI

struct LyricRibbonView: View {
    let model: LyricRibbonModel
    let layout: LyricRibbonLayout
    let onHide: () -> Void
    let onDragHeader: (NSEvent) -> Void
    @FocusState private var focusedControl: LyricRibbonControl?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var isTimed: Bool { if case .timed = model.content { true } else { false } }
    private var elapsed: String {
        let seconds = max(0, model.snapshot.positionMs) / 1000
        return "\(seconds / 60):\(String(format: "%02lld", seconds % 60))"
    }
    private var status: String {
        if model.isHeld { return String(localized: "status.reading", defaultValue: "Reading", table: "LyricRibbon") }
        if model.projection?.interval == .ended { return "End of lyrics" }
        if isTimed { return model.snapshot.isPlaying ? "Live" : "Paused" }
        return "Lyrics"
    }
    private var words: NSAttributedString {
        if case let .plain(text) = model.content {
            return LyricRibbonLayout.passage(previous: nil, current: text, scale: layout.textScale,
                isRightToLeft: model.source?.isRightToLeft ?? false)
        }
        if let current = model.projection?.current {
            return LyricRibbonLayout.passage(previous: model.projection?.previous?.text,
                current: current.text, scale: layout.textScale, isRightToLeft: model.source?.isRightToLeft ?? false)
        }
        let message: String = switch model.content {
        case .loading: "Loading lyrics…"
        case .instrumental: "Instrumental"
        case .noMatch: "No lyrics found"
        case .failure: "Lyrics unavailable"
        case let .idle(reason): reason.message
        case .plain: ""
        case .timed:
            switch model.projection?.interval {
            case .beforeFirst: "Lyrics start soon"
            case .ended: "End of lyrics"
            default: "♪"
            }
        }
        return NSAttributedString(string: message, attributes: [
            .font: NSFont.systemFont(ofSize: 17 * layout.textScale), .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(spacing: LyricRibbonLayout.sectionSpacing) {
                HStack(spacing: 8) {
                    HStack(spacing: 8) {
                        vinylMark
                        VStack(alignment: .leading, spacing: 1) {
                            Text(model.snapshot.title).font(.system(size: 12, weight: .medium))
                            if !model.snapshot.artist.isEmpty {
                                Text(model.snapshot.artist).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .help(model.snapshot.artist.isEmpty ? model.snapshot.title : "\(model.snapshot.title) · \(model.snapshot.artist)")
                    .overlay { LyricHeaderDrag(onDrag: onDragHeader) }
                    Text(elapsed).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary).fixedSize()
                    dismissControl
                }
                .frame(height: LyricRibbonLayout.headerHeight)
                LyricPassageView(text: words, width: layout.panelSize.width - 2 * LyricRibbonLayout.horizontalInset,
                    height: layout.textViewportHeight, resetRevision: model.scrollResetRevision)
                    .frame(height: layout.textViewportHeight)
                if let attribution = model.source?.attribution, layout.attributionHeight > 0 {
                    Text(attribution).font(.system(size: 11 * layout.textScale)).foregroundStyle(.secondary)
                        .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: layout.attributionHeight, alignment: .topLeading)
                        .help(attribution).accessibilityLabel(attribution)
                }
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Circle().fill(model.isHeld ? Color(red: 0.86, green: 0.77, blue: 0.59) : .secondary)
                            .frame(width: 5, height: 5).accessibilityHidden(true)
                        Text(status).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    }
                    .foregroundStyle(model.isHeld ? Color(red: 0.86, green: 0.77, blue: 0.59) : .secondary)
                    .help(model.isHeld ? (model.snapshot.isPlaying ? "Reading · music continues" : "Reading · music paused") : status)
                    Spacer(minLength: 0)
                    if isTimed { readingControl.fixedSize().layoutPriority(1) }
                }
                .frame(height: LyricRibbonLayout.footerHeight)
            }
            .padding(.horizontal, LyricRibbonLayout.horizontalInset)
            .padding(.vertical, LyricRibbonLayout.verticalInset)
            .frame(width: layout.panelSize.width, height: layout.panelSize.height)
            .background {
                let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
                if reduceTransparency || contrast == .increased {
                    shape.fill(Color(nsColor: .windowBackgroundColor))
                } else {
                    shape.fill(.regularMaterial)
                        .overlay { shape.fill(Color(red: 0.075, green: 0.09, blue: 0.08).opacity(0.86)) }
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(.primary.opacity(contrast == .increased ? 0.5 : 0.1), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .controlSize(.small)
        .preferredColorScheme(.dark)
        .onChange(of: model.keyboardSelection) { _, selection in focusedControl = selection }
    }

    @ViewBuilder private var readingControl: some View {
        if reduceTransparency || contrast == .increased { readingToggle.buttonStyle(.bordered) }
        else { readingToggle.buttonStyle(.glass) }
    }

    private var readingToggle: some View {
        Toggle(isOn: Binding(
            get: { model.isHeld },
            set: { if $0 { model.holdText() } else { model.backToLive() } }
        )) {
            Text(model.isHeld ? "Back to live" : "Hold text")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary).frame(minHeight: 22)
        }
        .toggleStyle(.button)
        .buttonBorderShape(.capsule)
        .accessibilityLabel("Hold text")
        .help(String(localized: "action.hold.help", defaultValue: "Hold the words while music continues. Return to live to follow the current line.", table: "LyricRibbon"))
        .disabled(!model.isHeld && model.projection?.interval != .cue)
        .focusable(interactions: [.edit, .activate])
        .focused($focusedControl, equals: .reading)
        .tint(model.isHeld ? Color(red: 0.86, green: 0.77, blue: 0.59) : nil)
    }

    @ViewBuilder private var dismissControl: some View {
        if reduceTransparency || contrast == .increased { dismissButton.buttonStyle(.bordered) }
        else { dismissButton.buttonStyle(.glass) }
    }

    private var dismissButton: some View {
        Button(action: onHide) {
            Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.primary).frame(width: 16, height: 20)
        }
        .buttonBorderShape(.circle)
        .accessibilityLabel("Hide Ribbon").help("Hide Ribbon")
        .focusable(interactions: [.edit, .activate]).focused($focusedControl, equals: .hide)
    }

    private var vinylMark: some View {
        ZStack {
            Circle().fill(Color(red: 0.10, green: 0.14, blue: 0.11))
            ForEach([12.0, 17.0, 21.0], id: \.self) { size in
                Circle().stroke(.secondary.opacity(0.45), lineWidth: 0.6).frame(width: size, height: size)
            }
            Circle().fill(Color(red: 0.79, green: 0.70, blue: 0.54)).frame(width: 7, height: 7)
            Circle().fill(.black.opacity(0.7)).frame(width: 2, height: 2)
        }.frame(width: 22, height: 22).accessibilityHidden(true)
    }
}

struct LyricPassageView: NSViewRepresentable {
    let text: NSAttributedString
    let width: CGFloat
    let height: CGFloat
    let resetRevision: UInt64

    final class Coordinator {
        var resetRevision: UInt64?
        private var layoutWidth: CGFloat?
        private var textHeight: CGFloat = 0
        private var currentCueOffset: CGFloat = 0

        func updateText(_ view: NSTextView, text: NSAttributedString, width: CGFloat, height: CGFloat) {
            guard let storage = view.textStorage, let container = view.textContainer,
                  let manager = view.layoutManager else { return }
            let width = max(1, width)
            let textChanged = !storage.isEqual(to: text)
            if textChanged { storage.setAttributedString(text) }
            if textChanged || layoutWidth != width {
                container.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
                manager.ensureLayout(for: container)
                textHeight = ceil(manager.usedRect(for: container).height)
                currentCueOffset = 0
                storage.enumerateAttribute(LyricRibbonLayout.currentCueAttribute,
                    in: NSRange(location: 0, length: storage.length)) { value, range, stop in
                    guard value as? Bool == true else { return }
                    let glyph = manager.glyphIndexForCharacter(at: range.location)
                    guard glyph < manager.numberOfGlyphs else { return }
                    let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                    let font = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
                    let context = font.map { ceil($0.ascender - $0.descender + $0.leading) + 8 } ?? 0
                    currentCueOffset = max(0, line.minY - context)
                    stop.pointee = true
                }
                layoutWidth = width
            }
            // Trailing room lets even a short current cue sit below one line of preceding context.
            let size = CGSize(width: width, height: max(height, textHeight, currentCueOffset + height))
            if view.frame.size != size { view.setFrameSize(size) }
        }

        func updateScroll(_ scroll: NSScrollView, resetRevision: UInt64) {
            guard self.resetRevision != resetRevision else { return }
            scroll.contentView.scroll(to: CGPoint(x: 0, y: currentCueOffset))
            scroll.reflectScrolledClipView(scroll.contentView)
            self.resetRevision = resetRevision
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let container = NSTextContainer(size: CGSize(width: max(1, width), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let manager = NSLayoutManager()
        manager.addTextContainer(container)
        let storage = NSTextStorage()
        storage.addLayoutManager(manager)
        let view = NSTextView(frame: .zero, textContainer: container)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        // The coordinator owns document height, including room below the current-cue anchor.
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.setAccessibilityLabel("Lyrics")
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        context.coordinator.updateText(view, text: text, width: width, height: height)
        context.coordinator.updateScroll(scroll, resetRevision: resetRevision)
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
    if kind == "reading" { model.holdText() }
    let layout = LyricRibbonLayout.measure(content: content, width: 448, textScale: 1, availableHeight: 320)
    return LyricRibbonView(model: model, layout: layout, onHide: {}, onDragHeader: { _ in })
}

#Preview("Live lyrics") { previewLyricRibbon("live") }
#Preview("Reading lyrics") { previewLyricRibbon("reading") }
#Preview("Long lyrics") { previewLyricRibbon("long") }
#Preview("Plain lyrics") { previewLyricRibbon("plain") }
#Preview("Unavailable lyrics") { previewLyricRibbon("unavailable") }
#Preview("Right-to-left lyrics") { previewLyricRibbon("rtl") }
#endif
