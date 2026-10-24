import AppKit
import BopifyPlayback
import CoreGraphics
import QuartzCore
import SwiftUI
import Testing

@MainActor @Suite("Native lyric reader", .serialized)
struct LyricReaderTests {
    @Test(arguments: [1.0, 1.5]) func followingCentersVisibleGlyphsInEachRow(scale: CGFloat) throws {
        let document = try LyricDocument(cues: (0..<3).map {
            LyricCue(id: String($0), startMs: Int64($0) * 1000, text: "HHH")
        })
        let text = LyricRibbonLayout.reader(content: .timed(document),
            projection: document.project(positionMs: 1000, durationMs: 3000), isReading: false, scale: scale)
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 300, height: 1000))
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        let centers: [CGFloat] = try [0, 4, 8].map { character in
            let font = try #require(storage.attribute(.font, at: character, effectiveRange: nil) as? NSFont)
            let glyph = manager.glyphIndexForCharacter(at: character)
            let row = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            return row.minY + manager.location(forGlyphAt: glyph).y - font.capHeight / 2
        }
        #expect(abs((centers[1] - centers[0]) - (centers[2] - centers[1])) < 1)
    }

    @Test func cueHitTestingRequiresVisibleTimedWords() throws {
        let reader = try LyricReaderFixture()
        reader.update(position: 3_000, reading: true)
        let range = (reader.view.string as NSString).range(of: "Upcoming words")
        let glyph = reader.manager.glyphIndexForCharacter(at: range.location)
        let box = reader.manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: reader.view.textContainer!)
        #expect(reader.view.seekTimestamp(at: CGPoint(x: box.midX, y: box.midY)) == 4000)
        #expect(reader.view.seekTimestamp(at: CGPoint(x: 299, y: box.midY)) == nil)
        reader.view.setFrameSize(CGSize(width: 300, height: reader.view.frame.height + 80))
        #expect(reader.view.seekTimestamp(at: CGPoint(x: 10, y: reader.view.frame.height - 1)) == nil)
        reader.update(position: 1_000, reading: false)
        let hidden = reader.manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: reader.view.textContainer!)
        #expect(reader.view.seekTimestamp(at: CGPoint(x: hidden.midX, y: hidden.midY)) == nil)
        reader.coordinator.updateText(reader.view, text: NSAttributedString(string: "Untimed words"), width: 300, height: 65)
        #expect(reader.view.seekTimestamp(at: CGPoint(x: 5, y: 5)) == nil)
    }

    @Test func indirectLinkActivationSeeksWithoutAMouseEvent() throws {
        let reader = try LyricReaderFixture()
        reader.update(position: 3_000, reading: true)
        let range = (reader.view.string as NSString).range(of: "Upcoming words")
        var seeks: [Int64] = []
        reader.view.onSeek = { seeks.append($0) }

        reader.view.clicked(onLink: "4000", at: range.location)

        #expect(seeks == [4000])
    }

    @Test func indirectLinkActivationRejectsHiddenOrReplacedCues() throws {
        let reader = try LyricReaderFixture()
        reader.update(position: 1_000, reading: false)
        let range = (reader.view.string as NSString).range(of: "Upcoming words")
        var seeks: [Int64] = []
        reader.view.onSeek = { seeks.append($0) }
        reader.view.clicked(onLink: "4000", at: range.location)

        reader.update(position: 3_000, reading: true)
        reader.view.clicked(onLink: "3000", at: range.location)
        reader.view.clicked(onLink: "4000", at: -1)
        reader.view.clicked(onLink: "4000", at: reader.view.string.utf16.count)
        reader.coordinator.updateText(reader.view, text: NSAttributedString(string: "Untimed words"), width: 300, height: 65)
        reader.view.clicked(onLink: "4000", at: 0)

        #expect(seeks.isEmpty)
    }

    @Test func manualViewportFitsThreeVisualRowsWithoutAFourth() throws {
        let reader = try LyricReaderFixture()
        reader.update(position: 0, reading: true)
        let layout = LyricRibbonLayout.measure(width: 448, textScale: 1, availableHeight: 1000)
        let third = (reader.view.string as NSString).range(of: "Previous words")
        let fourth = (reader.view.string as NSString).range(of: "Current words")
        #expect(reader.lineTop(at: third.location) < layout.textViewportHeight)
        #expect(reader.lineTop(at: fourth.location) >= layout.textViewportHeight - 0.01)
    }

    @Test func largerTextReanchorsFollowingWithoutAPlaybackTick() throws {
        let reader = try LyricReaderFixture()
        reader.update(position: 3_000, reading: false)
        reader.coordinator.updateScroll(reader.scroll, resetRevision: 1)
        reader.scroll.setFrameSize(CGSize(width: 300, height: 141))
        reader.coordinator.updateContent(reader.scroll, content: .timed(reader.document),
            projection: reader.document.project(positionMs: 3_000, durationMs: 7_000), reading: false,
            scale: 1.5, rtl: false, fallback: NSAttributedString(), width: 300, height: 141)
        reader.coordinator.updateScroll(reader.scroll, resetRevision: 1)
        let current = (reader.view.string as NSString).range(of: "Current words")
        #expect(abs(reader.lineTop(at: current.location) - reader.scroll.contentView.bounds.minY - 42) < 1)
    }

    @Test func followingRetainsFullDocumentAndShowsOnlyAdjacentCues() throws {
        let reader = try LyricReaderFixture()
        reader.update(position: 3_000, reading: false)

        #expect(reader.view.string == "Opening words\nEarlier words\nPrevious words\nCurrent words\nUpcoming words\nLater words\nClosing words")
        for word in ["Previous words", "Current words", "Upcoming words"] {
            #expect(try reader.foreground(of: word).alphaComponent > 0)
        }
        for word in ["Opening words", "Earlier words", "Later words", "Closing words"] {
            #expect(try reader.foreground(of: word).alphaComponent == 0)
        }

        reader.update(position: 4_000, reading: false)
        #expect(try reader.foreground(of: "Previous words").alphaComponent == 0)
        #expect(try reader.foreground(of: "Later words").alphaComponent > 0)
        #expect(reader.view.string.hasPrefix("Opening words"))
        #expect(reader.view.string.hasSuffix("Closing words"))
    }

    @Test func manualReadingRevealsEarlierAndLaterCues() throws {
        let reader = try LyricReaderFixture()
        reader.update(position: 3_000, reading: false)
        reader.update(position: 3_000, reading: true)

        for word in reader.words {
            #expect(try reader.foreground(of: word).alphaComponent > 0)
        }
        reader.update(position: 6_000, reading: true)
        #expect(try reader.foreground(of: "Opening words").alphaComponent > 0)
        #expect(try reader.foreground(of: "Closing words").alphaComponent > 0)
    }

    @Test func manualHighlightFollowsPlaybackWithoutMovingReadingPosition() throws {
        let reader = try LyricReaderFixture()
        reader.update(position: 3_000, reading: true)
        #expect(try reader.foreground(of: "Current words") == NSColor.labelColor)
        #expect(try reader.foreground(of: "Previous words") == NSColor.secondaryLabelColor)
        let origin = reader.scroll.contentView.bounds.origin
        let measurements = reader.manager.measurements
        reader.view.setSelectedRange(NSRange(location: 2, length: 4))
        reader.update(position: 4_000, reading: true)
        #expect(try reader.foreground(of: "Current words") == NSColor.secondaryLabelColor)
        #expect(try reader.foreground(of: "Upcoming words") == NSColor.labelColor)
        #expect(reader.scroll.contentView.bounds.origin == origin)
        #expect(reader.view.selectedRange() == NSRange(location: 2, length: 4))
        #expect(reader.manager.measurements == measurements)
    }

    @Test func enteringManualReadingPreservesVisibleWordsAndSelection() throws {
        let reader = try LyricReaderFixture()
        reader.update(position: 3_000, reading: false)
        let range = (reader.view.string as NSString).range(of: "Current words")
        reader.scroll.contentView.scroll(to: CGPoint(x: 0, y: reader.lineTop(at: range.location) + 3))
        reader.scroll.reflectScrolledClipView(reader.scroll.contentView)
        let selection = NSRange(location: range.location + 2, length: 5)
        reader.view.setSelectedRange(selection)
        let visibleOffset = reader.lineTop(at: range.location) - reader.scroll.documentVisibleRect.minY

        reader.update(position: 3_000, reading: true)

        #expect(reader.view.selectedRange() == selection)
        #expect(abs(reader.lineTop(at: range.location) - reader.scroll.documentVisibleRect.minY - visibleOffset) < 1)
        #expect(reader.scroll.documentVisibleRect.minY > 0)
    }

    @Test func readingClockUpdatesPreserveLayoutAndManualScroll() throws {
        let reader = try LyricReaderFixture()
        reader.update(position: 1_000, reading: true)
        reader.scroll.contentView.scroll(to: CGPoint(x: 0, y: 30))
        reader.scroll.reflectScrolledClipView(reader.scroll.contentView)
        reader.view.setSelectedRange(NSRange(location: 2, length: 4))
        let origin = reader.scroll.contentView.bounds.origin
        let measurements = reader.manager.measurements

        for position: Int64 in [2_000, 3_000, 4_000, 6_000, 7_000] {
            reader.update(position: position, reading: true)
        }

        #expect(reader.manager.measurements == measurements)
        #expect(reader.scroll.contentView.bounds.origin == origin)
        #expect(reader.view.selectedRange() == NSRange(location: 2, length: 4))
    }

    @Test func programmaticFollowingDoesNotBeginReadingButReaderNavigationDoes() throws {
        let reader = try LyricReaderFixture()
        var readingRequests = 0
        reader.scroll.onBeginReading = { readingRequests += 1 }
        reader.view.onBeginReading = { readingRequests += 1 }
        reader.update(position: 1_000, reading: false)
        reader.coordinator.updateScroll(reader.scroll, resetRevision: 1)
        reader.update(position: 4_000, reading: false)
        reader.coordinator.updateScroll(reader.scroll, resetRevision: 2)
        #expect(readingRequests == 0)
        let before = reader.scroll.contentView.bounds.minY
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 126))

        reader.view.keyDown(with: event)

        #expect(readingRequests == 1)
        #expect(reader.scroll.contentView.bounds.minY < before)
    }

    @Test func cueEmphasisUsesOneGlyphLayerAndRetainsNativeTextAndSelection() throws {
        let reader = try LyricReaderFixture()
        let panel = NSPanel(contentRect: reader.scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = reader.scroll
        panel.orderFront(nil)
        defer { panel.orderOut(nil); panel.close() }
        reader.view.wantsLayer = true
        reader.update(position: 3_000, reading: false)
        let words = reader.view.string
        let previous = (words as NSString).range(of: "Current words")
        let origin = reader.scroll.contentView.bounds.origin
        let height = reader.view.frame.height
        let selection = NSRange(location: 2, length: 4)
        reader.view.setSelectedRange(selection)

        reader.update(position: 4_000, reading: false, animated: true)

        let emphasis = try #require(reader.view.layer?.animation(forKey: "lyricEmphasis") as? CABasicAnimation)
        #expect(emphasis.keyPath == "opacity")
        #expect(reader.view.layer?.animation(forKey: kCATransition) == nil)
        #expect(reader.view.string == words)
        #expect(reader.view.selectedRange() == selection)
        let current = (words as NSString).range(of: "Upcoming words")
        #expect(reader.view.textStorage?.attribute(LyricRibbonLayout.currentCueAttribute, at: current.location, effectiveRange: nil) as? Bool == true)
        #expect(reader.view.textStorage?.attribute(LyricRibbonLayout.currentCueAttribute, at: previous.location, effectiveRange: nil) == nil)
        #expect(reader.scroll.contentView.bounds.origin == origin)
        #expect(reader.view.frame.height == height)

        reader.update(position: 5_000, reading: false, animated: true)
        #expect(reader.view.selectedRange() == selection)
        reader.update(position: 5_000, reading: false, animated: false)
        #expect(reader.view.layer?.animation(forKey: "lyricEmphasis") == nil)
        reader.update(position: 6_000, reading: false, animated: true)
        #expect(reader.view.layer?.animation(forKey: "lyricEmphasis") != nil)
        reader.coordinator.cancelFollow(reader.scroll)
        #expect(reader.view.layer?.animation(forKey: "lyricEmphasis") == nil)
    }

    @Test(arguments: [CarouselDirection.next, .previous, .fade])
    func trackChangeTransitionsTheViewportBeforeReplacingLyrics(direction: CarouselDirection) throws {
        let reader = try LyricReaderFixture()
        let panel = NSPanel(contentRect: reader.scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = reader.scroll
        panel.orderFront(nil)
        defer { panel.orderOut(nil); panel.close() }
        reader.view.wantsLayer = true
        reader.update(position: 3_000, reading: false)
        reader.coordinator.transitionTrack(reader.scroll, occurrenceID: "first", direction: .next, animated: true)
        #expect(reader.scroll.contentView.layer?.animation(forKey: kCATransition) == nil)

        reader.coordinator.transitionTrack(reader.scroll, occurrenceID: "none", direction: .fade, animated: true)
        reader.coordinator.updateContent(reader.scroll, content: .idle(.loadingTrack), projection: nil, reading: false,
            scale: 1, rtl: false, fallback: NSAttributedString(string: "Loading track…"), width: 300, height: 65)
        reader.coordinator.transitionTrack(reader.scroll, occurrenceID: "second", direction: direction, animated: true)
        let transition = try #require(reader.scroll.contentView.layer?.animation(forKey: kCATransition) as? CATransition)
        #expect(transition.type == (direction == .fade ? .fade : .push))
        #expect(transition.subtype == (direction == .next ? .fromRight : direction == .previous ? .fromLeft : nil))
        #expect(transition.duration >= 0.4)
        #expect(reader.scroll.contentView.layer?.bounds.width == reader.scroll.contentView.bounds.width)
        reader.coordinator.updateContent(reader.scroll, content: .loading, projection: nil, reading: false,
            scale: 1, rtl: false, fallback: NSAttributedString(string: "Loading lyrics…"), width: 300, height: 65)
        #expect(reader.scroll.contentView.layer?.animation(forKey: kCATransition) != nil)
        reader.scroll.contentView.layer?.removeAnimation(forKey: kCATransition)
        reader.coordinator.transitionTrack(reader.scroll, occurrenceID: "second", direction: direction, animated: true)
        reader.update(position: 3_000, reading: false)
        #expect(reader.scroll.contentView.layer?.animation(forKey: kCATransition) == nil)

        reader.coordinator.transitionTrack(reader.scroll, occurrenceID: "third", direction: .previous, animated: true)
        let previous = try #require(reader.scroll.contentView.layer?.animation(forKey: kCATransition) as? CATransition)
        #expect(previous.subtype == .fromLeft)
        reader.coordinator.transitionTrack(reader.scroll, occurrenceID: "fourth", direction: .next, animated: false)
        #expect(reader.scroll.contentView.layer?.animation(forKey: kCATransition) == nil)
        reader.coordinator.transitionTrack(reader.scroll, occurrenceID: "fourth", direction: .next, animated: true)
        #expect(reader.scroll.contentView.layer?.animation(forKey: kCATransition) == nil)
    }

    @Test(arguments: [CarouselDirection.next, .previous])
    func swipingTransitionsOutgoingLyricsBeforeTransientLoading(direction: CarouselDirection) throws {
        let reader = try LyricReaderFixture()
        let panel = NSPanel(contentRect: reader.scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = reader.scroll
        panel.orderFront(nil)
        defer { panel.orderOut(nil); panel.close() }
        reader.update(position: 3_000, reading: false)
        reader.coordinator.updateScroll(reader.scroll, resetRevision: 1)
        reader.coordinator.transitionTrack(reader.scroll, occurrenceID: "first", direction: .fade, animated: true)
        reader.scroll.prepareTrackSwipe(direction)
        reader.coordinator.transitionTrack(reader.scroll, occurrenceID: "first", direction: .fade, animated: true)
        reader.coordinator.transitionTrack(reader.scroll, occurrenceID: "none", direction: .fade,
            animated: true, content: .idle(.loadingTrack))
        let transition = try #require(reader.scroll.contentView.layer?.animation(forKey: kCATransition) as? CATransition)
        #expect(reader.view.string.contains("Current words"))
        #expect(transition.type == .push)
        #expect(transition.subtype == (direction == .next ? .fromRight : .fromLeft))
        reader.coordinator.updateContent(reader.scroll, content: .idle(.loadingTrack), projection: nil, reading: false,
            scale: 1, rtl: false, fallback: NSAttributedString(string: "Loading track…"), width: 300, height: 65)
        reader.coordinator.updateScroll(reader.scroll, resetRevision: 2, animated: true)
        #expect(reader.scroll.contentView.layer?.animation(forKey: "lyricFollow") == nil)
        reader.scroll.contentView.layer?.removeAnimation(forKey: kCATransition)
        reader.coordinator.transitionTrack(reader.scroll, occurrenceID: "second", direction: direction,
            animated: true, content: .loading)
        reader.coordinator.updateContent(reader.scroll, content: .loading, projection: nil, reading: false,
            scale: 1, rtl: false, fallback: NSAttributedString(string: "Loading lyrics…"), width: 300, height: 65)
        #expect(reader.scroll.contentView.layer?.animation(forKey: kCATransition) == nil)
        reader.coordinator.transitionTrack(reader.scroll, occurrenceID: "second", direction: direction, animated: true)
        reader.update(position: 3_000, reading: false)
        #expect(reader.scroll.contentView.layer?.animation(forKey: kCATransition) == nil)
        #expect(reader.scroll.takeTrackSwipe() == nil)
    }

    @Test func abandonedSwipeDirectionsExpireAndCannotAffectLaterNavigation() {
        let scroll = LyricReadingScrollView()
        scroll.prepareTrackSwipe(.next, at: 10)
        #expect(scroll.takeTrackSwipe(at: 12) == nil)
        scroll.prepareTrackSwipe(.previous, at: 20)
        scroll.prepareTrackSwipe(.next, at: 20.05)
        scroll.prepareTrackSwipe(.previous, at: 20.1)
        #expect(scroll.takeTrackSwipe(at: 20.1) == .previous)
        #expect(scroll.takeTrackSwipe(at: 20.2) == nil)
    }

    @Test(arguments: [true, false]) func horizontalSwipeNavigatesOnceWithEitherScrollPreference(inverted: Bool) {
        var gesture = LyricTrackSwipe()
        let left: CGFloat = inverted ? -1 : 1
        #expect(gesture.update(x: 0, y: 0, phase: .began, momentum: [], precise: true, inverted: inverted, timestamp: 0) == .pending)
        #expect(gesture.update(x: left * 20, y: 2, phase: .changed, momentum: [], precise: true, inverted: inverted, timestamp: 0.01) == .horizontal)
        #expect(gesture.update(x: left * 30, y: 1, phase: .changed, momentum: [], precise: true, inverted: inverted, timestamp: 0.02) == .next)
        #expect(gesture.update(x: left * 80, y: 0, phase: .changed, momentum: [], precise: true, inverted: inverted, timestamp: 0.03) == .horizontal)
        #expect(gesture.update(x: 0, y: 0, phase: .ended, momentum: [], precise: true, inverted: inverted, timestamp: 0.04) == .horizontal)
        #expect(gesture.update(x: -left * 100, y: 0, phase: [], momentum: .changed, precise: true, inverted: inverted, timestamp: 0.05) == .horizontal)
        #expect(gesture.update(x: -left * 50, y: 0, phase: .began, momentum: [], precise: true, inverted: inverted, timestamp: 0.06) == .previous)
    }

    @Test func verticalGestureRemainsReadingDespiteLaterHorizontalDrift() {
        var gesture = LyricTrackSwipe()
        #expect(gesture.update(x: 2, y: 15, phase: .began, momentum: [], precise: true, inverted: true, timestamp: 0) == .vertical)
        #expect(gesture.update(x: 80, y: 1, phase: .changed, momentum: [], precise: true, inverted: true, timestamp: 0.01) == .vertical)
        #expect(gesture.update(x: 0, y: 30, phase: .ended, momentum: [], precise: true, inverted: true, timestamp: 0.02) == .vertical)
        #expect(gesture.update(x: 0, y: 10, phase: [], momentum: .changed, precise: true, inverted: true, timestamp: 0.03) == .vertical)
    }

    @Test func shortCancelledAndOrdinaryWheelGesturesDoNotSkipTracks() {
        var gesture = LyricTrackSwipe()
        #expect(gesture.update(x: -30, y: 1, phase: .began, momentum: [], precise: true, inverted: true, timestamp: 0) == .horizontal)
        #expect(gesture.update(x: -30, y: 1, phase: .cancelled, momentum: [], precise: true, inverted: true, timestamp: 0.01) == .horizontal)
        #expect(gesture.update(x: -100, y: 0, phase: [], momentum: [], precise: false, inverted: true, timestamp: 0.02) == .vertical)
    }

    @Test func phaselessPreciseGesturesWaitForAQuietIntervalBeforeSkippingAgain() {
        var gesture = LyricTrackSwipe()
        #expect(gesture.update(x: -50, y: 1, phase: [], momentum: [], precise: true, inverted: true, timestamp: 0) == .next)
        #expect(gesture.update(x: -70, y: 0, phase: [], momentum: [], precise: true, inverted: true, timestamp: 0.1) == .horizontal)
        #expect(gesture.update(x: 50, y: 0, phase: [], momentum: [], precise: true, inverted: true, timestamp: 0.5) == .previous)
    }

    @Test func horizontalWheelCallbacksAreLimitedToCompactPanelAndPreserveReaderState() async throws {
        let model = LyricRibbonModel(snapshot: LyricPlaybackSnapshot(sessionID: "test", occurrenceID: "one",
            recordingID: "song", title: "Song", artist: "Artist", positionMs: 3_000,
            durationMs: 7_000, isPlaying: true, seekRevision: 0))
        model.show()
        model.completeLoad(.timed(try lyricTestDocument()), token: model.beginLoad())
        let layout = LyricRibbonLayout.measure(width: 448, textScale: 1, availableHeight: 320)
        var previous = 0
        var next = 0
        func root(compact: Bool) -> LyricPanelView {
            LyricPanelView(model: model, layout: layout, isCompact: compact,
                onPrevious: { previous += 1 }, onNext: { next += 1 })
        }
        let host = NSHostingView(rootView: root(compact: false))
        host.sizingOptions = []
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: layout.panelSize),
            styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        panel.orderFront(nil)
        defer { panel.orderOut(nil); panel.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        func passage(in view: NSView) -> LyricReadingScrollView? {
            if let scroll = view as? LyricReadingScrollView { return scroll }
            return view.subviews.lazy.compactMap { passage(in: $0) }.first
        }
        let scroll = try #require(passage(in: host))
        let view = try #require(scroll.documentView as? NSTextView)
        let wheel = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
            wheelCount: 2, wheel1: 0, wheel2: 60, wheel3: 0))
        wheel.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        let event = try #require(NSEvent(cgEvent: wheel))
        scroll.scrollWheel(with: event)
        #expect(previous == 0 && next == 0)
        #expect(!model.isReading)

        host.rootView = root(compact: true)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        view.setSelectedRange(NSRange(location: 2, length: 4))
        let origin = scroll.contentView.bounds.origin
        scroll.scrollWheel(with: event)
        scroll.scrollWheel(with: event)
        #expect(previous + next == 1)
        #expect(!model.isReading)
        #expect(view.selectedRange() == NSRange(location: 2, length: 4))
        #expect(scroll.contentView.bounds.origin == origin)
    }
}

@MainActor private final class LyricReaderFixture {
    let words = ["Opening words", "Earlier words", "Previous words", "Current words", "Upcoming words", "Later words", "Closing words"]
    let document: LyricDocument
    let manager = LyricReaderLayoutManager()
    let view: LyricReadingTextView
    let scroll = LyricReadingScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 65))
    let coordinator = LyricPassageView.Coordinator()

    init() throws {
        document = try LyricDocument(cues: words.enumerated().map {
            LyricCue(id: String($0.offset), startMs: Int64($0.offset) * 1_000, text: $0.element)
        })
        let container = NSTextContainer(size: .zero)
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        let storage = NSTextStorage()
        storage.addLayoutManager(manager)
        view = LyricReadingTextView(frame: .zero, textContainer: container)
        view.isEditable = false
        view.isSelectable = true
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.textContainerInset = .zero
        scroll.documentView = view
    }

    func update(position: Int64, reading: Bool, animated: Bool = false) {
        coordinator.updateContent(scroll, content: .timed(document),
            projection: document.project(positionMs: position, durationMs: 7_000), reading: reading,
            scale: 1, rtl: false, fallback: NSAttributedString(), width: 300, height: 65, animated: animated)
    }

    func foreground(of word: String) throws -> NSColor {
        let range = (view.string as NSString).range(of: word)
        try #require(range.location != NSNotFound)
        return try #require((manager.temporaryAttribute(.foregroundColor, atCharacterIndex: range.location, effectiveRange: nil)
            ?? view.textStorage?.attribute(.foregroundColor, at: range.location, effectiveRange: nil)) as? NSColor)
    }

    func lineTop(at character: Int) -> CGFloat {
        manager.lineFragmentRect(forGlyphAt: manager.glyphIndexForCharacter(at: character), effectiveRange: nil).minY
    }
}

nonisolated private final class LyricReaderLayoutManager: NSLayoutManager {
    var measurements = 0
    override func ensureLayout(for container: NSTextContainer) {
        measurements += 1
        super.ensureLayout(for: container)
    }
}
