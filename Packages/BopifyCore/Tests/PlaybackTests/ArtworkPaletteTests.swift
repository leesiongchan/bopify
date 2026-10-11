import Testing
import BopifyPlayback

@Suite("ArtworkPalette") struct ArtworkPaletteTests {
    private let red = ArtworkColor(red: 1, green: 0, blue: 0)
    private let green = ArtworkColor(red: 0, green: 1, blue: 0)
    private let blue = ArtworkColor(red: 0, green: 0, blue: 1)
    private let grey = ArtworkColor(red: 0.5, green: 0.5, blue: 0.5)

    @Test(arguments: [[0, 1, 2], [2, 0, 1], [1, 2, 0]]) func saturatedColoursFollowWeight(order: [Int]) {
        let samples = [(color: red, weight: 0.6), (color: green, weight: 0.3), (color: blue, weight: 0.1)]
        #expect(ArtworkPalette.classify(order.map { samples[$0] }) == .marble(red, green, blue))
    }

    @Test func equalWeightsUseStableColourOrdering() {
        #expect(ArtworkPalette.classify([(red, 1), (blue, 1), (green, 1)]) == .marble(blue, green, red))
        #expect(ArtworkPalette.classify([(green, 1), (red, 1), (blue, 1)]) == .marble(blue, green, red))
    }

    @Test func greyscaleAndNearNeutralUseDominantTint() {
        let black = ArtworkColor(red: 0, green: 0, blue: 0)
        let white = ArtworkColor(red: 1, green: 1, blue: 1)
        #expect(ArtworkPalette.classify([(black, 0.1), (grey, 0.7), (white, 0.2)]) == .tinted(grey))
        let nearGrey = ArtworkColor(red: 0.51, green: 0.50, blue: 0.49)
        #expect(ArtworkPalette.classify([(nearGrey, 1)]) == .tinted(nearGrey))
    }

    @Test func emptySaturatedClustersDoNotColourAGreyscaleCover() {
        #expect(ArtworkPalette.classify([(grey, 1), (red, 0), (blue, 0)]) == .tinted(grey))
    }

    @Test func sparseClustersRepeatTheDominantColour() {
        #expect(ArtworkPalette.classify([(red, 1)]) == .marble(red, red, red))
        #expect(ArtworkPalette.classify([(red, 0.7), (green, 0.3)]) == .marble(red, green, red))
    }

    @Test func failedAndInvalidSamplesUseNeutral() {
        #expect(ArtworkPalette.classify([]) == .neutral)
        #expect(ArtworkPalette.classify([(red, 0), (green, -1), (blue, .nan)]) == .neutral)
        #expect(ArtworkPalette.classify([(ArtworkColor(red: .nan, green: 0, blue: 0), 1)]) == .neutral)
    }
}
