#if DEBUG
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
}
#endif
