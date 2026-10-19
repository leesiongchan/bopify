import AppKit
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

    func update(position: Int64, reading: Bool) {
        coordinator.updateContent(scroll, content: .timed(document),
            projection: document.project(positionMs: position, durationMs: 7_000), reading: reading,
            scale: 1, rtl: false, fallback: NSAttributedString(), width: 300, height: 65)
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
