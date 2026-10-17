#if DEBUG
import AppKit
import SwiftUI

struct LyricRibbonView: View {
    let model: LyricRibbonModel
    let layout: LyricRibbonLayout
    let onHide: () -> Void
    let onDragHeader: (NSEvent) -> Void
    @State private var hovered = false
    @FocusState private var controlsFocused: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var showsControls: Bool { hovered || controlsFocused || model.isHeld }
    private var isTimed: Bool { if case .timed = model.content { true } else { false } }
    private var elapsed: String {
        let seconds = max(0, model.snapshot.positionMs) / 1000
        return "\(seconds / 60):\(String(format: "%02lld", seconds % 60))"
    }
    private var status: String {
        if model.isHeld { return model.snapshot.isPlaying ? "Reading · music continues" : "Reading · music paused" }
        if model.projection?.interval == .ended { return "End of lyrics" }
        if isTimed { return model.snapshot.isPlaying ? "Live" : "Paused" }
        return "Lyrics"
    }
    private var words: NSAttributedString {
        if case let .plain(text) = model.content {
            return LyricRibbonLayout.passage(previous: nil, current: text, scale: layout.textScale)
        }
        if let current = model.projection?.current {
            return LyricRibbonLayout.passage(previous: model.projection?.previous?.text,
                current: current.text, scale: layout.textScale)
        }
        let message: String = switch model.content {
        case .loading: "Loading lyrics…"
        case .instrumental: "Instrumental"
        case .noMatch: "No lyrics found"
        case .failure: "Lyrics unavailable"
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
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                vinylMark
                Text("\(model.snapshot.title) · \(model.snapshot.artist)")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 8)
                Text(elapsed).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            .frame(height: 22)
            .overlay { LyricHeaderDrag(onDrag: onDragHeader) }
            LyricPassageView(text: words, width: layout.panelSize.width - 40,
                height: layout.textViewportHeight, resetRevision: model.scrollResetRevision)
                .frame(height: layout.textViewportHeight)
            HStack(spacing: 8) {
                Text(status).font(.system(size: 10))
                    .foregroundStyle(model.isHeld ? Color(red: 0.86, green: 0.77, blue: 0.59) : .secondary)
                Spacer(minLength: 4)
                HStack(spacing: 5) {
                    if isTimed {
                        Button(model.isHeld ? "Back to live" : "Hold text") {
                            if model.isHeld { model.backToLive() } else { model.holdText() }
                        }
                        .accessibilityValue(model.isHeld ? "Text held" : "Following playback")
                        .disabled(!model.isHeld && model.projection?.interval != .cue)
                        .focused($controlsFocused)
                        .tint(model.isHeld ? Color(red: 0.88, green: 0.82, blue: 0.70) : .secondary)
                    }
                    Button(action: onHide) { Image(systemName: "xmark").frame(width: 10) }
                        .accessibilityLabel("Hide Ribbon").help("Hide Ribbon").focused($controlsFocused)
                }
                .font(.system(size: 10)).buttonStyle(.bordered).buttonBorderShape(.capsule)
                .controlSize(.mini).opacity(showsControls ? 1 : 0)
            }
            .frame(height: 26)
        }
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 14)
        .frame(width: layout.panelSize.width, height: layout.panelSize.height)
        .background {
            let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
            if reduceTransparency || contrast == .increased {
                shape.fill(Color(nsColor: .windowBackgroundColor))
            } else {
                shape.fill(.regularMaterial)
                    .overlay(shape.fill(Color(red: 0.08, green: 0.10, blue: 0.085).opacity(0.86)))
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
            .strokeBorder(.primary.opacity(contrast == .increased ? 0.5 : 0.13), lineWidth: 1).allowsHitTesting(false))
        .preferredColorScheme(.dark)
        .onHover { hovered = $0 }
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

private struct LyricPassageView: NSViewRepresentable {
    let text: NSAttributedString
    let width: CGFloat
    let height: CGFloat
    let resetRevision: UInt64

    final class Coordinator { var resetRevision: UInt64? }
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
        view.isVerticallyResizable = true
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
        guard let view = scroll.documentView as? NSTextView, let storage = view.textStorage else { return }
        if !storage.isEqual(to: text) { storage.setAttributedString(text) }
        view.textContainer?.containerSize = CGSize(width: max(1, width), height: .greatestFiniteMagnitude)
        view.setFrameSize(CGSize(width: max(1, width), height: max(height, LyricRibbonLayout.textHeight(text, width: width))))
        if context.coordinator.resetRevision != resetRevision {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
            context.coordinator.resetRevision = resetRevision
        }
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
