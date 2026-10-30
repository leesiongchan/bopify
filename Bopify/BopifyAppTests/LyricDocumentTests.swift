import Testing

@Suite("Lyric document")
struct LyricDocumentTests {
    @Test func projectsTimestampBoundariesWithoutInventingAnEnd() throws {
        let doc = try lyricTestDocument()
        #expect(doc.project(positionMs: 9_999, durationMs: 100_000) == LyricProjection(next: doc.groups.first))
        #expect(doc.project(positionMs: 10_000, durationMs: 100_000).current?.occurrenceIDs == ["a"])
        let simultaneous = doc.project(positionMs: 20_000, durationMs: 100_000)
        #expect(simultaneous.current?.occurrenceIDs == ["b", "c"])
        #expect(simultaneous.current?.text == "Let the quiet settle in\nThere is light along the sill")
        #expect(simultaneous.previous?.startMs == 10_000)
        #expect(doc.project(positionMs: 30_000, durationMs: 100_000).current == nil)
        #expect(doc.project(positionMs: 69_999, durationMs: 100_000).current == nil)
        #expect(doc.project(positionMs: 70_000, durationMs: 100_000).current?.occurrenceIDs == ["repeat"])
        #expect(doc.project(positionMs: 99_999, durationMs: 100_000).current?.startMs == 80_000)
        #expect(doc.project(positionMs: 100_000, durationMs: 100_000) == LyricProjection(previous: doc.groups.last))
        #expect(doc.project(positionMs: 200_000, durationMs: 0).current?.startMs == 80_000)
    }

    @Test func sortsTimestampsAndPreservesSimultaneousSourceOrder() throws {
        let doc = try LyricDocument(cues: [
            LyricCue(id: "late", startMs: 200, text: "Same words"),
            LyricCue(id: "first", startMs: 0, text: "Same words"),
            LyricCue(id: "second", startMs: 0, text: "Another voice"),
        ])
        #expect(doc.groups.map(\.startMs) == [0, 200])
        #expect(doc.groups[0].occurrenceIDs == ["first", "second"])
        #expect(doc.project(positionMs: -100, durationMs: 1000).current?.startMs == 0)
        #expect(doc.project(positionMs: 200, durationMs: 1000).previous?.occurrenceIDs == ["first", "second"])
    }

    @Test func rejectsInvalidTimestampAndDuplicateOccurrence() {
        #expect(throws: LyricDocumentError.invalidTimestamp) {
            try LyricDocument(cues: [LyricCue(id: "a", startMs: -1, text: "Words")])
        }
        #expect(throws: LyricDocumentError.duplicateOccurrence) {
            try LyricDocument(cues: [LyricCue(id: "a", startMs: 0, text: "Words"), LyricCue(id: "a", startMs: 1, text: "Words")])
        }
    }

    @Test func emptyDocumentAndWhitespaceCueHaveNoCurrentWords() throws {
        #expect(try LyricDocument(cues: []).project(positionMs: 0, durationMs: 0).current == nil)
        let doc = try LyricDocument(cues: [LyricCue(id: "gap", startMs: 0, text: " \n ")])
        #expect(doc.project(positionMs: 10, durationMs: 100) == LyricProjection())
    }

    @Test func upcomingCueUsesAdjacentSourceGroups() throws {
        let doc = try lyricTestDocument()
        let opening = doc.project(positionMs: 0, durationMs: 100_000)
        #expect(opening.current == nil && opening.previous == nil)
        #expect(opening.next?.occurrenceIDs == ["a"])
        let first = doc.project(positionMs: 10_000, durationMs: 100_000)
        #expect(first.next?.occurrenceIDs == ["b", "c"])
        let beforeGap = doc.project(positionMs: 20_000, durationMs: 100_000)
        #expect(beforeGap.next?.occurrenceIDs == ["gap"])
        #expect(beforeGap.next?.text == "")
        let gap = doc.project(positionMs: 30_000, durationMs: 100_000)
        #expect(gap.current == nil)
        #expect(gap.next?.occurrenceIDs == ["repeat"])
        #expect(doc.project(positionMs: 80_000, durationMs: 100_000).next == nil)
    }

    @Test func endingKeepsLastGroupAsReaderAnchor() throws {
        let ended = try lyricTestDocument().project(positionMs: 100_000, durationMs: 100_000)
        #expect(ended.current == nil && ended.next == nil)
        #expect(ended.previous?.occurrenceIDs == ["next"])
    }

    @Test func beforeBlankOpeningDoesNotInventUpcomingWords() throws {
        let document = try LyricDocument(cues: [
            LyricCue(id: "gap", startMs: 10, text: " \n "),
            LyricCue(id: "words", startMs: 20, text: "Opening"),
        ])
        #expect(document.project(positionMs: 0, durationMs: 100).next == nil)
        #expect(document.project(positionMs: 10, durationMs: 100).next?.occurrenceIDs == ["words"])
        let empty = try LyricDocument(cues: []).project(positionMs: 100, durationMs: 100)
        #expect(empty.current == nil && empty.previous == nil && empty.next == nil)
    }
}

nonisolated func lyricTestDocument() throws -> LyricDocument {
    try LyricDocument(cues: [
        LyricCue(id: "a", startMs: 10_000, text: "Leave a little room for the rain"),
        LyricCue(id: "b", startMs: 20_000, text: "Let the quiet settle in"),
        LyricCue(id: "c", startMs: 20_000, text: "There is light along the sill"),
        LyricCue(id: "gap", startMs: 30_000, text: ""),
        LyricCue(id: "repeat", startMs: 70_000, text: "Leave a little room for the rain"),
        LyricCue(id: "next", startMs: 80_000, text: "Let the quiet settle in"),
    ])
}
