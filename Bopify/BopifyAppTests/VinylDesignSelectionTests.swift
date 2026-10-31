import Testing
import BopifyPlayback

@Suite("Vinyl selection continuity")
struct VinylDesignSelectionTests {
    @Test func globalStyleUpdatesAtRest() {
        var selection = VinylDesignSelection(rawValue: "bloom")
        selection.select(rawValue: "carnival")
        #expect(selection.appearance == .carnival)
    }

    @Test func latestStyleWaitsForCoverHandoff() {
        var selection = VinylDesignSelection(rawValue: "bloom")
        selection.beginHandoff()
        selection.select(rawValue: "drift")
        selection.select(rawValue: "carnival")
        #expect(selection.appearance == .bloom)
        selection.finishHandoff()
        #expect(selection.appearance == .carnival)
    }

    @Test func replacementCapturesLatestChoiceAndCancellationReleasesIt() {
        var selection = VinylDesignSelection(rawValue: "bloom")
        selection.beginHandoff()
        selection.select(rawValue: "drift")
        selection.beginHandoff()
        #expect(selection.appearance == .drift)
        selection.select(rawValue: "carnival")
        selection.finishHandoff()
        #expect(selection.appearance == .carnival)
    }

    @Test func mutedThenColorfulRestoresSavedStyle() throws {
        var selection = VinylDesignSelection(rawValue: "bloom")
        #expect(VinylDesignPalette.resolve(.neutral, design: selection.appearance) == nil)
        selection.select(rawValue: "carnival")
        #expect(VinylDesignPalette.resolve(.neutral, design: selection.appearance) == nil)
        let red = ArtworkColor(red: 1, green: 0, blue: 0)
        let palette = try #require(VinylDesignPalette.resolve(.marble(red, red, red), design: selection.appearance))
        #expect(selection.appearance == .carnival)
        #expect(palette.primary.red > palette.primary.green)
    }

    @Test func endingHandoffRetainsUserChoice() {
        var selection = VinylDesignSelection(rawValue: "rhapsody")
        selection.beginHandoff()
        selection.finishHandoff()
        #expect(selection.selected == .rhapsody)
        #expect(selection.appearance == .rhapsody)
    }

    @Test func outgoingSnapshotRetainsItsStyle() {
        var appearance = PressingAppearance(seed: 42, palette: .neutral, design: .bloom)
        let outgoing = appearance
        appearance.design = .carnival
        #expect(outgoing.design == .bloom)
        #expect(outgoing != appearance)
    }
}
