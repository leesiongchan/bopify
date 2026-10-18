import AppKit
import SwiftUI
import QuartzCore
import BopifyPlayback

struct LyricPassageView: NSViewRepresentable {
    var text = NSAttributedString()
    var content: LyricContent? = nil
    var projection: LyricProjection? = nil
    var isReading = false
    var textScale: CGFloat = 1
    var isRightToLeft = false
    let width: CGFloat
    let height: CGFloat
    let resetRevision: UInt64
    var animate = false
    var onBeginReading: () -> Void = {}
    var shouldFocusReader: () -> Bool = { false }
    var occurrenceID = ""
    var direction: CarouselDirection = .fade

    final class Coordinator {
        var resetRevision: UInt64?
        private var layoutWidth: CGFloat?
        private var textHeight: CGFloat = 0
        private var currentCueOffset: CGFloat = 0
        private var rendered: Input?
        private var occurrenceID: String?

        private struct Input: Equatable {
            let content: LyricContent
            let projection: LyricProjection?
            let reading: Bool
            let scale: CGFloat
            let rtl: Bool
        }

        func updateContent(_ scroll: NSScrollView, content: LyricContent, projection: LyricProjection?,
                           reading: Bool, scale: CGFloat, rtl: Bool, fallback: NSAttributedString,
                           width: CGFloat, height: CGFloat) {
            guard let view = scroll.documentView as? NSTextView else { return }
            let input = Input(content: content, projection: reading ? nil : projection,
                              reading: reading, scale: scale, rtl: rtl)
            let changesMetrics = input != rendered || layoutWidth != max(1, width)
            let anchor = reading && changesMetrics ? visibleAnchor(in: scroll) : nil
            if input != rendered {
                let words = LyricRibbonLayout.reader(content: content, projection: projection,
                    isReading: reading, scale: scale, isRightToLeft: rtl)
                updateText(view, text: words.length > 0 ? words : fallback, width: width, height: height)
                rendered = input
            } else if layoutWidth != max(1, width) || view.frame.height < height {
                updateText(view, text: view.attributedString(), width: width, height: height)
            }
            if let anchor, let manager = view.layoutManager, anchor.character < view.string.utf16.count {
                let glyph = manager.glyphIndexForCharacter(at: anchor.character)
                let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                scroll.contentView.scroll(to: CGPoint(x: 0, y: max(0, line.minY + anchor.offset)))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }

        private func visibleAnchor(in scroll: NSScrollView) -> (character: Int, offset: CGFloat)? {
            guard let view = scroll.documentView as? NSTextView, !view.string.isEmpty,
                  let manager = view.layoutManager, let container = view.textContainer else { return nil }
            let glyph = manager.glyphIndex(for: CGPoint(x: 0, y: scroll.contentView.bounds.minY + 1), in: container)
            guard glyph < manager.numberOfGlyphs else { return nil }
            let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            return (manager.characterIndexForGlyph(at: glyph), scroll.contentView.bounds.minY - line.minY)
        }

        func updateText(_ view: NSTextView, text: NSAttributedString, width: CGFloat, height: CGFloat) {
            guard let storage = view.textStorage, let container = view.textContainer,
                  let manager = view.layoutManager else { return }
            let width = max(1, width)
            let textChanged = !storage.isEqual(to: text)
            if textChanged {
                let selection = view.selectedRange()
                let sameWords = storage.string == text.string
                storage.setAttributedString(text)
                if sameWords { view.setSelectedRange(selection) }
            }
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
                    let context = font.map { ceil($0.ascender - $0.descender + $0.leading) + 6 } ?? 0
                    currentCueOffset = max(0, line.minY - context)
                    stop.pointee = true
                }
                layoutWidth = width
            }
            // The final cue needs room below it to retain the same live anchor.
            let size = CGSize(width: width, height: max(height, textHeight, currentCueOffset + height))
            if view.frame.size != size { view.setFrameSize(size) }
        }

        func transitionTrack(_ scroll: NSScrollView, occurrenceID: String, direction: CarouselDirection, animated: Bool) {
            defer { self.occurrenceID = occurrenceID }
            guard let old = self.occurrenceID, old != occurrenceID, let view = scroll.documentView,
                  animated, scroll.window?.isVisible == true else { return }
            view.wantsLayer = true
            guard let layer = view.layer else { return }
            let distance: CGFloat = switch direction { case .next: 9; case .previous: -9; case .fade: 0 }
            let movement = CABasicAnimation(keyPath: "position.x")
            movement.fromValue = layer.position.x + distance
            movement.toValue = layer.position.x
            movement.duration = 0.24
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.24
            layer.add(movement, forKey: "lyricTrackMove")
            layer.add(fade, forKey: "lyricTrackFade")
        }

        func cancelFollow(_ scroll: NSScrollView) {
            guard let layer = scroll.contentView.layer, layer.animation(forKey: "lyricFollow") != nil else { return }
            let visible = layer.presentation()?.bounds.origin ?? scroll.contentView.bounds.origin
            layer.removeAnimation(forKey: "lyricFollow")
            scroll.contentView.scroll(to: visible)
            scroll.reflectScrolledClipView(scroll.contentView)
        }

        func updateScroll(_ scroll: NSScrollView, resetRevision: UInt64, animated: Bool = false) {
            if !animated { cancelFollow(scroll) }
            guard self.resetRevision != resetRevision else { return }
            let previous = scroll.contentView.layer?.presentation()?.bounds.origin ?? scroll.contentView.bounds.origin
            let target = CGPoint(x: 0, y: currentCueOffset)
            scroll.contentView.scroll(to: target)
            scroll.reflectScrolledClipView(scroll.contentView)
            if animated, self.resetRevision != nil, scroll.window?.isVisible == true,
               let layer = scroll.contentView.layer, previous != target {
                let animation = CABasicAnimation(keyPath: "bounds.origin")
                animation.fromValue = NSValue(point: previous)
                animation.toValue = NSValue(point: scroll.contentView.bounds.origin)
                animation.duration = 0.24
                animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                layer.add(animation, forKey: "lyricFollow")
            }
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
        let view = LyricReadingTextView(frame: .zero, textContainer: container)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.setAccessibilityLabel("Lyrics")
        let scroll = LyricReadingScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.verticalScroller = LyricReadingScroller()
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.contentView.wantsLayer = true
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? LyricReadingTextView else { return }
        let coordinator = context.coordinator
        let begin = { [weak scroll] in
            if let scroll { coordinator.cancelFollow(scroll) }
            onBeginReading()
        }
        (scroll as? LyricReadingScrollView)?.onBeginReading = begin
        (scroll.verticalScroller as? LyricReadingScroller)?.onBeginReading = begin
        view.onBeginReading = begin
        if let content {
            coordinator.updateContent(scroll, content: content, projection: projection, reading: isReading,
                scale: textScale, rtl: isRightToLeft, fallback: text, width: width, height: height)
        } else { coordinator.updateText(view, text: text, width: width, height: height) }
        coordinator.transitionTrack(scroll, occurrenceID: occurrenceID, direction: direction, animated: animate)
        if !animate { view.layer?.removeAllAnimations() }
        if shouldFocusReader() {
            // SwiftUI finishes removing the focused Sync control after this update.
            DispatchQueue.main.async { [weak view] in
                guard let view, shouldFocusReader(), let window = view.window, window.isKeyWindow else { return }
                window.makeFirstResponder(view)
            }
        }
        if isReading { coordinator.cancelFollow(scroll) }
        else { coordinator.updateScroll(scroll, resetRevision: resetRevision, animated: animate) }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.cancelFollow(scroll)
        (scroll as? LyricReadingScrollView)?.onBeginReading = nil
        (scroll.verticalScroller as? LyricReadingScroller)?.onBeginReading = nil
        (scroll.documentView as? LyricReadingTextView)?.onBeginReading = nil
    }
}

final class LyricReadingScrollView: NSScrollView {
    var onBeginReading: (() -> Void)?
    override func scrollWheel(with event: NSEvent) {
        if event.scrollingDeltaY != 0 || event.phase == .began { onBeginReading?() }
        super.scrollWheel(with: event)
    }
}

private final class LyricReadingScroller: NSScroller {
    nonisolated override class var isCompatibleWithOverlayScrollers: Bool { true }
    var onBeginReading: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onBeginReading?(); super.mouseDown(with: event) }
}

final class LyricReadingTextView: NSTextView {
    var onBeginReading: (() -> Void)?
    override var acceptsFirstResponder: Bool { window?.canBecomeKey ?? false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onBeginReading?(); super.mouseDown(with: event) }
    override func cancelOperation(_ sender: Any?) { window?.cancelOperation(sender) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelOperation(nil); return }
        guard !event.modifierFlags.contains(.command), let scroll = enclosingScrollView else { super.keyDown(with: event); return }
        if event.keyCode == 48 {
            window?.keyDown(with: event)
            return
        }
        let navigationKeys: Set<UInt16> = [126, 125, 116, 121, 115, 119, 49]
        guard navigationKeys.contains(event.keyCode) else { super.keyDown(with: event); return }
        onBeginReading?()
        let visible = scroll.contentView.bounds
        let target: CGFloat
        switch event.keyCode {
        case 126: target = visible.minY - 24
        case 125: target = visible.minY + 24
        case 116: target = visible.minY - visible.height * 0.9
        case 121: target = visible.minY + visible.height * 0.9
        case 115: target = 0
        case 119: target = frame.height
        case 49: target = visible.minY + visible.height * (event.modifierFlags.contains(.shift) ? -0.9 : 0.9)
        default: super.keyDown(with: event); return
        }
        scroll.contentView.scroll(to: CGPoint(x: 0, y: min(max(0, target), max(0, frame.height - visible.height))))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}
