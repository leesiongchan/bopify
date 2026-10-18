import AppKit
import Testing
import BopifyDomain

@MainActor @Suite("Lyric presentation")
struct LyricPresentationTests {
    @Test func timedConversionKeepsSourceOccurrencesAndMetadata() throws {
        let value = try LyricPresentation(lyrics: presentationLyrics())
        guard case let .timed(document) = value.content else { Issue.record("Expected timed content"); return }
        #expect(document.groups.map(\.startMs) == [1000, 2000])
        #expect(document.groups[0].occurrenceIDs == ["0", "1"])
        #expect(document.groups[0].text == "A quiet street\n")
        #expect(document.groups[1].occurrenceIDs == ["2"])
        #expect(document.groups[1].text == "The lamps return")
        #expect(value.source.provider == "fixture")
        #expect(value.source.providerDisplayName == "Fixture provider")
        #expect(value.source.language == "ar")
        #expect(value.source.isRightToLeft)
    }

    @Test func unsyncedConversionPreservesBlankLines() throws {
        let input = presentationLyrics(sync: .unsynced, lines: [
            TrackLyricLine(text: "First", startTimeMs: nil), TrackLyricLine(text: "", startTimeMs: nil),
            TrackLyricLine(text: "Last", startTimeMs: nil)])
        #expect(try LyricPresentation(lyrics: input).content == .plain("First\n\nLast"))
    }

    @Test(arguments: [Int64?.none, -1])
    func invalidTimedStartsFail(start: Int64?) {
        #expect(throws: LyricDocumentError.invalidTimestamp) {
            try LyricPresentation(lyrics: presentationLyrics(lines: [TrackLyricLine(text: "Words", startTimeMs: start)]))
        }
    }

    @Test func attributionUsesOnlySuppliedProviderValues() {
        #expect(LyricSourceMetadata(lyrics: presentationLyrics()).attribution == "Fixture provider")
        #expect(LyricSourceMetadata(lyrics: presentationLyrics(displayName: "")).attribution == "fixture")
        #expect(LyricSourceMetadata(lyrics: presentationLyrics(provider: "", displayName: "")).attribution == nil)
    }

    @Test func staleTokensCannotReplaceAttributionAndInvalidationClearsIt() throws {
        let model = LyricRibbonModel(snapshot: lyricTestSnapshot())
        model.show()
        let old = model.beginLoad()
        let fresh = model.beginLoad()
        let source = LyricSourceMetadata(lyrics: presentationLyrics())
        model.completeLoad(.timed(try lyricTestDocument()), token: fresh, source: source)
        model.beginReading()
        model.completeLoad(.plain("Old words"), token: old,
                           source: LyricSourceMetadata(lyrics: presentationLyrics(displayName: "Old provider")))
        #expect(model.source == source)
        #expect(model.isReading)
        _ = model.beginLoad()
        #expect(model.source == nil)
        model.completeLoad(.plain("New words"), token: model.beginLoad(), source: source)
        var next = model.snapshot
        next.occurrenceID = "replacement"
        model.update(next)
        #expect(model.source == nil)
        model.completeLoad(.timed(try lyricTestDocument()), token: model.beginLoad(), source: source)
        model.beginReading()
        model.setIdle(.otherDevice)
        model.beginReading()
        #expect(model.content == .idle(.otherDevice))
        #expect(model.source == nil && !model.isReading && model.projection == nil)
        #expect(model.isVisible)
    }

    @Test func attributionSharesFooterWithoutChangingCueGeometry() throws {
        let source = LyricSourceMetadata(lyrics: presentationLyrics(displayName: String(repeating: "Fixture provider ", count: 30)))
        let content = LyricContent.timed(try lyricTestDocument())
        let layout = LyricRibbonLayout.measure(content: content, width: 250, textScale: 1.5,
                                               availableHeight: 240, source: source)
        #expect(layout.panelSize.height <= 240)
        #expect(layout.textViewportHeight > 0)
        let model = LyricRibbonModel(snapshot: lyricTestSnapshot())
        model.show()
        model.completeLoad(content, token: model.beginLoad(), source: source)
        for position: Int64 in [1000, 20_000, 72_000, 87_000] {
            model.update(lyricTestSnapshot(position: position))
            let measured = LyricRibbonLayout.measure(content: model.content, width: 250, textScale: 1.5,
                                                      availableHeight: 240, source: model.source)
            #expect(measured.panelSize == layout.panelSize)
        }
        let original = LyricRibbonLayout.measure(content: .plain("Short"), width: 448, textScale: 1, availableHeight: 480)
        #expect(original.panelSize.height == 226)
        #expect(original.panelSize == LyricRibbonLayout.measure(content: .plain("Short"), width: 448,
            textScale: 1, availableHeight: 480, source: source).panelSize)
    }

    @Test func rightToLeftMetadataControlsParagraphDirection() throws {
        let text = LyricRibbonLayout.passage(previous: "Previous", current: "للنافذة ضوء هادئ", scale: 1, isRightToLeft: true)
        for index in [0, text.length - 1] {
            let style = try #require(text.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle)
            #expect(style.baseWritingDirection == .rightToLeft)
        }
    }
}

nonisolated func presentationLyrics(sync: LyricSynchronization = .lineSynced,
    lines: [TrackLyricLine] = [TrackLyricLine(text: "A quiet street", startTimeMs: 1000),
        TrackLyricLine(text: "", startTimeMs: 1000), TrackLyricLine(text: "The lamps return", startTimeMs: 2000)],
    provider: String = "fixture", displayName: String = "Fixture provider") -> TrackLyrics {
    TrackLyrics(trackURI: SpotifyURI("spotify:track:11dFghVXANMlKmJXsNCbNl")!, synchronization: sync,
                lines: lines, provider: provider, providerDisplayName: displayName, language: "ar", isRightToLeft: true)
}
