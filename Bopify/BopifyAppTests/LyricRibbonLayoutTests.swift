import AppKit
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
        #expect(long.textViewportHeight > short.textViewportHeight)
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

    @Test func measuresRightToLeftMultilinePassages() throws {
        let layout = LyricRibbonLayout.measure(content: try content("للنافذة ضوء هادئ\nوللصباح متسع جديد"),
            width: 320, textScale: 1, availableHeight: 480)
        #expect(layout.panelSize.height <= 480)
        #expect(layout.textViewportHeight >= 50)
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
}

nonisolated private final class LyricLayoutManagerSpy: NSLayoutManager {
    var measurements = 0
    override func ensureLayout(for container: NSTextContainer) {
        measurements += 1
        super.ensureLayout(for: container)
    }
}
