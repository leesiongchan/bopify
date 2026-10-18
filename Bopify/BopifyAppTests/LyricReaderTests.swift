import AppKit
import Testing

@MainActor @Suite("Native lyric reader", .serialized)
struct LyricReaderTests {
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
        return try #require(view.textStorage?.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor)
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
