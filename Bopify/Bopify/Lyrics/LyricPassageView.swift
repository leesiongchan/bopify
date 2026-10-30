import AppKit
import Carbon.HIToolbox
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
    var onSeek: (Int64) -> Void = { _ in }
    var onPrevious: (() -> Void)? = nil
    var onNext: (() -> Void)? = nil

    final class Coordinator {
        var resetRevision: UInt64?
        private var layoutWidth: CGFloat?
        private var textHeight: CGFloat = 0
        private var currentCueOffset: CGFloat = 0
        private var rendered: Input?
        private var occurrenceID: String?
        private var swipedThroughLoading = false
        private var highlightedStart: Int64?

        private struct Input: Equatable {
            let content: LyricContent
            let projection: LyricProjection?
            let reading: Bool
            let scale: CGFloat
            let rtl: Bool
        }

        func updateContent(_ scroll: NSScrollView, content: LyricContent, projection: LyricProjection?,
                           reading: Bool, scale: CGFloat, rtl: Bool, fallback: NSAttributedString,
                           width: CGFloat, height: CGFloat, animated: Bool = false) {
            guard let view = scroll.documentView as? NSTextView else { return }
            let input = Input(content: content, projection: reading ? nil : projection,
                              reading: reading, scale: scale, rtl: rtl)
            let geometryChanged = layoutWidth != max(1, width) || rendered?.scale != scale || rendered?.rtl != rtl
            let changesMetrics = input != rendered || geometryChanged
            if !animated || reading || geometryChanged || rendered?.content != content {
                view.layer?.removeAnimation(forKey: "lyricEmphasis")
            } else if let rendered, !rendered.reading,
                      rendered.projection?.current?.startMs != projection?.current?.startMs,
                      scroll.window?.isVisible == true {
                // Fade one rendered layer; crossfading resized glyph snapshots doubles their outlines.
                view.wantsLayer = true
                let emphasis = CABasicAnimation(keyPath: "opacity")
                emphasis.fromValue = 0.78
                emphasis.toValue = 1
                emphasis.duration = 0.28
                emphasis.timingFunction = CAMediaTimingFunction(name: .easeOut)
                view.layer?.add(emphasis, forKey: "lyricEmphasis")
            }
            if !reading && geometryChanged { resetRevision = nil }
            let anchor = reading && changesMetrics ? visibleAnchor(in: scroll) : nil
            if input != rendered {
                let words = LyricRibbonLayout.reader(content: content, projection: projection,
                    isReading: reading, scale: scale, isRightToLeft: rtl)
                updateText(view, text: words.length > 0 ? words : fallback, width: width, height: height)
                rendered = input
            } else if layoutWidth != max(1, width) || view.frame.height < height {
                updateText(view, text: view.attributedString(), width: width, height: height)
            }
            if reading, changesMetrics || highlightedStart != projection?.current?.startMs,
               let storage = view.textStorage, let manager = view.layoutManager {
                let range = NSRange(location: 0, length: storage.length)
                manager.addTemporaryAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, forCharacterRange: range)
                storage.enumerateAttribute(LyricRibbonLayout.cueTimeAttribute, in: range) { value, range, _ in
                    if let time = value as? Int64, time == projection?.current?.startMs {
                        manager.addTemporaryAttribute(.foregroundColor, value: NSColor.labelColor, forCharacterRange: range)
                    }
                }
                highlightedStart = projection?.current?.startMs
            } else if !reading {
                view.layoutManager?.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: view.string.utf16.count))
                highlightedStart = nil
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
                    let style = storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
                    let context = max(style?.minimumLineHeight ?? 0, font.map { ceil($0.ascender - $0.descender + $0.leading) + 6 } ?? 0)
                    currentCueOffset = max(0, line.minY - context)
                    stop.pointee = true
                }
                layoutWidth = width
            }
            // The final cue needs room below it to retain the same live anchor.
            let size = CGSize(width: width, height: max(height, textHeight, currentCueOffset + height))
            if view.frame.size != size { view.setFrameSize(size) }
        }

        func transitionTrack(_ scroll: NSScrollView, occurrenceID: String, direction: CarouselDirection,
                             animated: Bool, content: LyricContent? = nil) {
            let reader = scroll as? LyricReadingScrollView
            if !animated {
                scroll.contentView.layer?.removeAnimation(forKey: kCATransition)
                reader?.clearTrackSwipe()
                swipedThroughLoading = false
            }
            // Transient playback gaps retain the last confirmed track's identity.
            guard !occurrenceID.isEmpty, occurrenceID != "none" else {
                guard case .idle(.loadingTrack)? = content else {
                    reader?.clearTrackSwipe()
                    swipedThroughLoading = false
                    return
                }
                if self.occurrenceID != nil, animated, let direction = reader?.takeTrackSwipe() {
                    swipedThroughLoading = true
                    animateTrack(scroll, direction: direction)
                }
                return
            }
            let changed = self.occurrenceID != occurrenceID
            defer {
                self.occurrenceID = occurrenceID
                if changed || swipedThroughLoading {
                    swipedThroughLoading = false
                    reader?.clearTrackSwipe()
                }
            }
            guard let old = self.occurrenceID, old != occurrenceID,
                  !swipedThroughLoading, animated else { return }
            animateTrack(scroll, direction: direction)
        }

        private func animateTrack(_ scroll: NSScrollView, direction: CarouselDirection) {
            guard scroll.window?.isVisible == true else { return }
            cancelFollow(scroll)
            scroll.contentView.wantsLayer = true
            guard let layer = scroll.contentView.layer else { return }
            layer.masksToBounds = true
            let transition = CATransition()
            transition.type = direction == .fade ? .fade : .push
            transition.subtype = switch direction { case .next: .fromRight; case .previous: .fromLeft; case .fade: nil }
            transition.duration = 0.45
            transition.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            layer.add(transition, forKey: kCATransition)
        }

        func cancelFollow(_ scroll: NSScrollView) {
            scroll.documentView?.layer?.removeAnimation(forKey: "lyricEmphasis")
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
               let layer = scroll.contentView.layer, previous != target,
               layer.animation(forKey: kCATransition) == nil {
                let animation = CABasicAnimation(keyPath: "bounds.origin")
                animation.fromValue = NSValue(point: previous)
                animation.toValue = NSValue(point: scroll.contentView.bounds.origin)
                animation.duration = 0.4
                animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
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
        view.linkTextAttributes = [:]
        view.displaysLinkToolTips = false
        view.drawsBackground = false
        view.wantsLayer = true
        view.textContainerInset = .zero
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.setAccessibilityLabel("Lyrics")
        let scroll = LyricReadingScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
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
        if case .plain? = content { scroll.hasVerticalScroller = true }
        else { scroll.hasVerticalScroller = isReading }
        let begin = { [weak scroll] in
            if let scroll { coordinator.cancelFollow(scroll) }
            onBeginReading()
        }
        (scroll as? LyricReadingScrollView)?.onBeginReading = begin
        (scroll as? LyricReadingScrollView)?.onPrevious = onPrevious
        (scroll as? LyricReadingScrollView)?.onNext = onNext
        if onPrevious == nil, onNext == nil { (scroll as? LyricReadingScrollView)?.clearTrackSwipe() }
        (scroll.verticalScroller as? LyricReadingScroller)?.onBeginReading = begin
        view.onBeginReading = begin
        view.onSeek = onSeek
        // Capture the outgoing viewport before replacing its text, including loading placeholders.
        coordinator.transitionTrack(scroll, occurrenceID: occurrenceID, direction: direction, animated: animate, content: content)
        if let content {
            coordinator.updateContent(scroll, content: content, projection: projection, reading: isReading,
                scale: textScale, rtl: isRightToLeft, fallback: text, width: width, height: height, animated: animate)
        } else { coordinator.updateText(view, text: text, width: width, height: height) }
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
        scroll.contentView.layer?.removeAnimation(forKey: kCATransition)
        scroll.documentView?.layer?.removeAllAnimations()
        (scroll as? LyricReadingScrollView)?.onBeginReading = nil
        (scroll as? LyricReadingScrollView)?.onPrevious = nil
        (scroll as? LyricReadingScrollView)?.onNext = nil
        (scroll as? LyricReadingScrollView)?.clearTrackSwipe()
        (scroll.verticalScroller as? LyricReadingScroller)?.onBeginReading = nil
        (scroll.documentView as? LyricReadingTextView)?.onBeginReading = nil
        (scroll.documentView as? LyricReadingTextView)?.onSeek = nil
    }
}

final class LyricReadingScrollView: NSScrollView {
    var onBeginReading: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    private var swipe = LyricTrackSwipe()
    private var pendingTrackSwipe: (direction: CarouselDirection, expiresAt: TimeInterval)?

    func prepareTrackSwipe(_ direction: CarouselDirection, at time: TimeInterval = CACurrentMediaTime()) {
        pendingTrackSwipe = (direction, time + 1)
    }

    func takeTrackSwipe(at time: TimeInterval = CACurrentMediaTime()) -> CarouselDirection? {
        defer { clearTrackSwipe() }
        guard let pendingTrackSwipe, pendingTrackSwipe.expiresAt > time else { return nil }
        return pendingTrackSwipe.direction
    }

    func clearTrackSwipe() { pendingTrackSwipe = nil }

    override func scrollWheel(with event: NSEvent) {
        if onPrevious != nil || onNext != nil {
            switch swipe.update(x: event.scrollingDeltaX, y: event.scrollingDeltaY,
                phase: event.phase, momentum: event.momentumPhase, precise: event.hasPreciseScrollingDeltas,
                inverted: event.isDirectionInvertedFromDevice, timestamp: event.timestamp) {
            case .previous:
                if let onPrevious { prepareTrackSwipe(.previous); onPrevious() }
                return
            case .next:
                if let onNext { prepareTrackSwipe(.next); onNext() }
                return
            case .horizontal, .pending: return
            case .vertical: break
            }
        } else { swipe = LyricTrackSwipe() }
        if event.scrollingDeltaY != 0 { onBeginReading?() }
        super.scrollWheel(with: event)
    }
}

struct LyricTrackSwipe {
    enum Outcome { case pending, horizontal, vertical, previous, next }
    private var axis: Outcome = .pending
    private var x: CGFloat = 0
    private var y: CGFloat = 0
    private var triggered = false
    private var lastTimestamp: TimeInterval?

    mutating func update(x deltaX: CGFloat, y deltaY: CGFloat, phase: NSEvent.Phase, momentum: NSEvent.Phase,
                         precise: Bool, inverted: Bool, timestamp: TimeInterval) -> Outcome {
        guard momentum.isEmpty else { return axis == .vertical ? .vertical : .horizontal }
        guard precise else { return .vertical }
        if phase.contains(.began) || (phase.isEmpty && lastTimestamp.map { timestamp - $0 > 0.25 } != false) {
            self = LyricTrackSwipe()
        }
        lastTimestamp = timestamp
        if phase.contains(.cancelled) { triggered = true; return axis }
        x += deltaX
        y += deltaY
        if axis == .pending, max(abs(x), abs(y)) >= 6 { axis = abs(x) > abs(y) ? .horizontal : .vertical }
        guard axis == .horizontal, !triggered, abs(x) >= 48 else { return axis }
        triggered = true
        // Natural scrolling follows the fingers; conventional scrolling reverses the deltas.
        let physicalX = inverted ? x : -x
        return physicalX < 0 ? .next : .previous
    }
}

private final class LyricReadingScroller: NSScroller {
    nonisolated override class var isCompatibleWithOverlayScrollers: Bool { true }
    var onBeginReading: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onBeginReading?(); super.mouseDown(with: event) }
}

final class LyricReadingTextView: NSTextView {
    var onSeek: ((Int64) -> Void)?
    private var pendingSeek: (time: Int64, action: (Int64) -> Void)?
    private var isHandlingMouseDown = false

    func visibleCharacter(at point: CGPoint) -> Int? {
        guard let manager = layoutManager, let container = textContainer, let storage = textStorage else { return nil }
        let point = CGPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = manager.glyphIndex(for: point, in: container)
        guard glyph < manager.numberOfGlyphs,
              manager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil).contains(point) else { return nil }
        let character = manager.characterIndexForGlyph(at: glyph)
        guard character < storage.length else { return nil }
        let color = (manager.temporaryAttribute(.foregroundColor, atCharacterIndex: character, effectiveRange: nil)
            ?? storage.attribute(.foregroundColor, at: character, effectiveRange: nil)) as? NSColor
        guard color?.alphaComponent != 0 else { return nil }
        return character
    }

    func seekTimestamp(at point: CGPoint) -> Int64? {
        guard let character = visibleCharacter(at: point) else { return nil }
        return textStorage?.attribute(LyricRibbonLayout.cueTimeAttribute, at: character, effectiveRange: nil) as? Int64
    }

    override func clicked(onLink link: Any, at charIndex: Int) {
        guard let time = (link as? String).flatMap(Int64.init) else { return }
        if isHandlingMouseDown {
            guard let pendingSeek, pendingSeek.time == time else { return }
            pendingSeek.action(time)
        } else {
            // Accessibility can activate a link without entering the mouse tracking loop.
            guard let storage = textStorage, charIndex >= 0, charIndex < storage.length,
                  storage.attribute(LyricRibbonLayout.cueTimeAttribute, at: charIndex, effectiveRange: nil) as? Int64 == time else { return }
            let color = (layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: charIndex, effectiveRange: nil)
                ?? storage.attribute(.foregroundColor, at: charIndex, effectiveRange: nil)) as? NSColor
            guard color?.alphaComponent != 0 else { return }
            onSeek?(time)
        }
    }
    var onBeginReading: (() -> Void)?
    override var acceptsFirstResponder: Bool { window?.canBecomeKey ?? false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        isHandlingMouseDown = true
        pendingSeek = nil
        if event.clickCount == 1, event.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty,
           let time = seekTimestamp(at: convert(event.locationInWindow, from: nil)), let onSeek {
            pendingSeek = (time, onSeek)
        }
        onBeginReading?()
        defer { pendingSeek = nil; isHandlingMouseDown = false }
        super.mouseDown(with: event)
    }
    override func cancelOperation(_ sender: Any?) { window?.cancelOperation(sender) }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if !isEditable, let panel = window as? StatusPanel, panel.firstResponder === self,
           panel.handlePlaybackShortcut(with: event) { return true }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if !isEditable, let panel = window as? StatusPanel {
            if panel.handlePlaybackShortcut(with: event) { return }
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if (event.keyCode == kVK_Tab && (modifiers.isEmpty || modifiers == .shift))
                || (event.keyCode == kVK_Return && modifiers.isEmpty) {
                panel.keyDown(with: event)
                return
            }
        }
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
