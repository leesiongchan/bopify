import Testing
import BopifyPlayback

@Suite("Muted record designs")
struct RecordDesignTests {
    @Test func stableIDsAndInvalidFallback() {
        #expect(RecordDesign.allCases.map(\.rawValue) == ["classic", "glass", "nacre"])
        #expect(RecordDesign.resolve(nil) == .classic)
        #expect(RecordDesign.resolve("removed") == .classic)
        #expect(RecordDesign.resolve("glass") == .glass)
        #expect(RecordDesign.resolve("nacre") == .nacre)
        #expect(RecordDesign.glassSmokeDensity == Float(0.50))
        #expect(RecordDesign.preferenceKey != VinylDesign.preferenceKey)
    }

    @Test(arguments: RecordDesign.allCases)
    func materialsApplyOnlyToMutedPalettes(design: RecordDesign) {
        #expect(design.resolved(for: .neutral) == design)
        #expect(design.resolved(for: .tinted(ArtworkColor(red: 0.5, green: 0.5, blue: 0.5))) == design)
        let c = ArtworkColor(red: 1, green: 0, blue: 0)
        #expect(design.resolved(for: .marble(c, c, c)) == .classic)
        #expect(design.resolved(for: nil) == .classic)
    }

    @Test func appearanceSnapshotsIncludeMaterial() {
        var appearance = PressingAppearance(seed: 42, palette: .neutral, recordDesign: .glass)
        let outgoing = appearance
        appearance.recordDesign = .nacre
        #expect(outgoing.recordDesign == .glass)
        #expect(outgoing != appearance)
    }
}
