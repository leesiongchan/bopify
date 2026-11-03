import Testing
import BopifyPlayback

@Suite("Vinyl selection continuity")
struct VinylDesignSelectionTests {
    @Test func latestStyleWaitsForCoverHandoff() {
        var selection = VinylDesignSelection(rawValue: "bloom")
        selection.beginHandoff()
        selection.select(rawValue: "undertow")
        selection.select(rawValue: "carnival")
        #expect(selection.appearance == .bloom)
        selection.finishHandoff()
        #expect(selection.appearance == .carnival)
    }

    @Test func replacementCapturesLatestChoiceAndCancellationReleasesIt() {
        var selection = VinylDesignSelection(rawValue: "bloom")
        selection.beginHandoff()
        selection.select(rawValue: "undertow")
        selection.beginHandoff()
        #expect(selection.appearance == .undertow)
        selection.select(rawValue: "carnival")
        selection.finishHandoff()
        #expect(selection.appearance == .carnival)
    }
}
