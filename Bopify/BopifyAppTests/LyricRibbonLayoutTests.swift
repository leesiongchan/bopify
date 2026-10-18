import AppKit
import SwiftUI
import Testing

@MainActor @Suite("Lyric ribbon layout")
struct LyricRibbonLayoutTests {
    private func content(_ text: String) throws -> LyricContent {
        .timed(try LyricDocument(cues: [LyricCue(id: "a", startMs: 0, text: text),
            LyricCue(id: "b", startMs: 1000, text: "Another quiet afternoon")]))
    }

    @Test func reservesAllWrappedWordsAndLargerText() throws {
        let short = LyricRibbonLayout.measure(content: try content("One line"), width: 448, textScale: 1, availableHeight: 1000)
        let words = Array(repeating: "Leave a little room for the rain.", count: 10).joined(separator: " ")
        let long = LyricRibbonLayout.measure(content: try content(words), width: 448, textScale: 1, availableHeight: 1000)
        let scaled = LyricRibbonLayout.measure(content: try content(words), width: 448, textScale: 1.5, availableHeight: 1000)
        let bounded = LyricRibbonLayout.measure(content: try content(words), width: 448, textScale: 1, availableHeight: 320)
        #expect(long.textViewportHeight == short.textViewportHeight)
        #expect(long.panelSize.height <= 160)
        #expect(long.textViewportHeight <= 96)
        #expect(scaled.textViewportHeight >= long.textViewportHeight)
        #expect(bounded.panelSize.height <= 320)
        #expect(bounded.textViewportHeight > 0)
    }

    @Test func plainAndEmptyContentStayReachableOnNarrowScreens() throws {
        for value in [LyricContent.plain(String(repeating: "Words with room to read. ", count: 100)),
                      .timed(try LyricDocument(cues: [])), .loading] {
            let layout = LyricRibbonLayout.measure(content: value, width: 250, textScale: 1.5, availableHeight: 240)
            #expect(layout.panelSize.width == 250)
            #expect(layout.panelSize.height <= 240)
            #expect(layout.textViewportHeight.isFinite && layout.textViewportHeight > 0)
        }
    }

    @Test func reusesPassageLayoutAcrossClockUpdatesAndViewportChanges() {
        let manager = LyricLayoutManagerSpy()
        let container = NSTextContainer(size: .zero)
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        let storage = NSTextStorage()
        storage.addLayoutManager(manager)
        let view = NSTextView(frame: .zero, textContainer: container)
        let coordinator = LyricPassageView.Coordinator()
        let text = LyricRibbonLayout.passage(previous: nil, current: "A quiet afternoon", scale: 1)
        coordinator.updateText(view, text: text, width: 408, height: 59)
        #expect(manager.measurements == 1)
        view.setSelectedRange(NSRange(location: 2, length: 5))
        for _ in 0..<10 {
            coordinator.updateText(view, text: text.copy() as! NSAttributedString, width: 408, height: 59)
        }
        coordinator.updateText(view, text: text, width: 408, height: 120)
        #expect(manager.measurements == 1)
        #expect(view.frame.height == 120)
        #expect(view.selectedRange() == NSRange(location: 2, length: 5))
    }

    @Test func remeasuresPassageWhenWordsStyleOrWidthChange() {
        let manager = LyricLayoutManagerSpy()
        let container = NSTextContainer(size: .zero)
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        let storage = NSTextStorage()
        storage.addLayoutManager(manager)
        let view = NSTextView(frame: .zero, textContainer: container)
        let coordinator = LyricPassageView.Coordinator()
        let words = String(repeating: "A quiet afternoon. ", count: 10)
        let text = LyricRibbonLayout.passage(previous: nil, current: words, scale: 1)
        coordinator.updateText(view, text: text, width: 408, height: 1)
        let wideHeight = view.frame.height
        coordinator.updateText(view, text: text, width: 180, height: 1)
        #expect(view.frame.height > wideHeight)
        coordinator.updateText(view, text: LyricRibbonLayout.passage(previous: nil, current: words, scale: 1.5),
            width: 180, height: 1)
        coordinator.updateText(view, text: LyricRibbonLayout.passage(previous: nil, current: "New cue", scale: 1.5),
            width: 180, height: 1)
        #expect(manager.measurements == 4)
        #expect(storage.string == "New cue")
        #expect(view.frame.height == LyricRibbonLayout.textHeight(storage, width: 180))
    }

    @Test func longPassagesKeepACompactScrollableViewport() throws {
        let layout = LyricRibbonLayout.measure(content: try content(String(repeating: "A little room for the rain. ", count: 100)),
            width: 448, textScale: 1, availableHeight: 1000)
        #expect(layout.textViewportHeight <= 180)
        #expect(layout.panelSize.height < 350)
    }

    @Test func longPreviousCueCannotObscureTheCurrentLine() throws {
        let container = NSTextContainer(size: .zero)
        container.lineFragmentPadding = 0
        let manager = NSLayoutManager()
        manager.addTextContainer(container)
        let storage = NSTextStorage()
        storage.addLayoutManager(manager)
        let view = NSTextView(frame: .zero, textContainer: container)
        view.textContainerInset = .zero
        view.isVerticallyResizable = true
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 250, height: 120))
        scroll.documentView = view
        let coordinator = LyricPassageView.Coordinator()
        let previous = String(repeating: "A quiet street with room to read.\n", count: 20)
        let current = "The lamps return"
        let text = LyricRibbonLayout.passage(previous: previous, current: current, scale: 1)
        coordinator.updateText(view, text: text, width: 250, height: 120)
        coordinator.updateScroll(scroll, resetRevision: 1)

        let currentRange = (text.string as NSString).range(of: current)
        let glyphs = manager.glyphRange(forCharacterRange: currentRange, actualCharacterRange: nil)
        let currentRect = manager.boundingRect(forGlyphRange: glyphs, in: container)
        #expect(scroll.documentVisibleRect.intersects(currentRect))
        #expect(scroll.documentVisibleRect.minY > 0)
        #expect(currentRect.minY - scroll.documentVisibleRect.minY < 40)

        scroll.contentView.scroll(to: .zero)
        view.setSelectedRange(NSRange(location: 0, length: 5))
        coordinator.updateText(view, text: text, width: 250, height: 120)
        coordinator.updateScroll(scroll, resetRevision: 1)
        #expect(scroll.documentVisibleRect.minY == 0)
        #expect(view.selectedRange() == NSRange(location: 0, length: 5))

        coordinator.updateScroll(scroll, resetRevision: 2)
        #expect(scroll.documentVisibleRect.intersects(currentRect))
    }

    @Test func hostedReaderUsesOverlayScrollerWithoutClippingWrappedText() async throws {
        let text = LyricRibbonLayout.passage(previous: nil, current: String(repeating: "A quiet street with room to read. ", count: 20), scale: 1)
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 250, height: 120),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: LyricPassageView(text: text, width: 250, height: 120, resetRevision: 1))
        host.sizingOptions = []
        panel.contentView = host
        panel.orderFront(nil)
        defer { panel.orderOut(nil); panel.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        func passage(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap { passage(in: $0) }.first
        }
        let scroll = try #require(passage(in: host))
        let view = try #require(scroll.documentView as? NSTextView)
        #expect(scroll.scrollerStyle == .overlay)
        #expect(view.textContainer?.containerSize.width == scroll.contentSize.width)
    }

    @Test func hostedPassageRetainsCurrentCuePositionAfterNativeLayout() async throws {
        let current = "The lamps return"
        let text = LyricRibbonLayout.passage(previous: String(repeating: "A quiet street.\n", count: 24),
            current: current, scale: 1)
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 250, height: 120),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: LyricPassageView(text: text, width: 250, height: 120, resetRevision: 1))
        host.sizingOptions = []
        panel.contentView = host
        panel.orderFront(nil)
        defer { panel.orderOut(nil); panel.close() }
        host.layoutSubtreeIfNeeded()
        // NSTextView can resize itself after SwiftUI attaches and lays out the scroll view.
        try await Task.sleep(for: .milliseconds(50))
        func passage(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView, scroll.documentView is NSTextView { return scroll }
            return view.subviews.lazy.compactMap { passage(in: $0) }.first
        }
        let scroll = try #require(passage(in: host))
        let view = try #require(scroll.documentView as? NSTextView)
        let manager = try #require(view.layoutManager)
        let container = try #require(view.textContainer)
        let range = (text.string as NSString).range(of: current)
        let rect = manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: range,
            actualCharacterRange: nil), in: container)
        #expect(scroll.documentVisibleRect.intersects(rect))
        #expect(rect.minY - scroll.documentVisibleRect.minY < 40)
    }
}

nonisolated private final class LyricLayoutManagerSpy: NSLayoutManager {
    var measurements = 0
    override func ensureLayout(for container: NSTextContainer) {
        measurements += 1
        super.ensureLayout(for: container)
    }
}
