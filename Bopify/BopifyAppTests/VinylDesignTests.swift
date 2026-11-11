import Testing
import BopifyPlayback

@Suite("Vinyl design colors")
struct VinylDesignTests {
    private let warm = ArtworkPalette.marble(
        ArtworkColor(red: 0.9333, green: 0.5098, blue: 0.4510),
        ArtworkColor(red: 0.7255, green: 0.8392, blue: 0.7608),
        ArtworkColor(red: 0.9569, green: 0.8745, blue: 0.6078))

    @Test func stableIDsAndFallback() {
        #expect(VinylDesign.allCases.map(\.rawValue) == ["original", "undertow", "strata", "bloom", "rhapsody", "carnival"])
        #expect(VinylDesign.resolve(nil) == .original)
        #expect(VinylDesign.resolve("removed-style") == .original)
        #expect(VinylDesign.resolve("bloom") == .bloom)
        #expect(VinylDesign.resolve("drift") == .original)
    }

    @Test func tintedPalettesBypassDesignColors() {
        #expect(VinylDesignPalette.resolve(.neutral, design: .bloom) == nil)
        #expect(VinylDesignPalette.resolve(.tinted(ArtworkColor(red: 0.5, green: 0.5, blue: 0.5)), design: .bloom) == nil)
    }

    @Test(arguments: [VinylDesign.original, .undertow, .strata])
    func originalAndContoursPreserveExtractedColors(design: VinylDesign) throws {
        let palette = try #require(VinylDesignPalette.resolve(warm, design: design))
        #expect(palette.primary == ArtworkColor(red: 0.9333, green: 0.5098, blue: 0.4510))
        #expect(palette.secondary == ArtworkColor(red: 0.7255, green: 0.8392, blue: 0.7608))
        #expect(palette.accent == ArtworkColor(red: 0.9569, green: 0.8745, blue: 0.6078))
    }

    @Test func neutralSlotsStayNeutral() throws {
        let white = ArtworkColor(red: 1, green: 1, blue: 1)
        let gray = ArtworkColor(red: 0.5, green: 0.5, blue: 0.5)
        let result = try #require(VinylDesignPalette.resolve(.marble(white, gray, ArtworkColor(red: 1, green: 0, blue: 0)), design: .bloom))
        #expect(result.primary == white)
        #expect(result.secondary == gray)
    }

    @Test func repeatedSlotsRemainFiniteAndRelated() throws {
        let red = ArtworkColor(red: 1, green: 0, blue: 0)
        let result = try #require(VinylDesignPalette.resolve(.marble(red, red, red), design: .bloom))
        #expect(result.primary == result.secondary && result.primary == result.accent)
        #expect(result.primary.red > result.primary.green)
        #expect(result.primary.green == result.primary.blue)
        for channel in [result.primary.red, result.primary.green, result.primary.blue] {
            #expect(channel.isFinite && (0...1).contains(channel))
        }
    }

}
