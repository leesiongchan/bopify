import Testing
import BopifyPlayback

@Suite("Vinyl design colors")
struct VinylDesignTests {
    private let warm = ArtworkPalette.marble(
        ArtworkColor(red: 0.9333, green: 0.5098, blue: 0.4510),
        ArtworkColor(red: 0.7255, green: 0.8392, blue: 0.7608),
        ArtworkColor(red: 0.9569, green: 0.8745, blue: 0.6078))

    @Test func stableIDsAndFallback() {
        #expect(VinylDesign.allCases.map(\.rawValue) == ["original", "undertow", "drift", "strata", "bloom", "rhapsody", "carnival"])
        #expect(VinylDesign.resolve(nil) == .original)
        #expect(VinylDesign.resolve("removed-style") == .original)
        #expect(VinylDesign.resolve("bloom") == .bloom)
    }

    @Test(arguments: VinylDesign.allCases)
    func tintedPalettesBypassDesignColors(design: VinylDesign) {
        #expect(VinylDesignPalette.resolve(.neutral, design: design) == nil)
        #expect(VinylDesignPalette.resolve(.tinted(ArtworkColor(red: 0.5, green: 0.5, blue: 0.5)), design: design) == nil)
    }

    @Test(arguments: [VinylDesign.original, .undertow, .drift, .strata])
    func originalAndContoursPreserveExtractedColors(design: VinylDesign) throws {
        let palette = try #require(VinylDesignPalette.resolve(warm, design: design))
        #expect(palette.primary == ArtworkColor(red: 0.9333, green: 0.5098, blue: 0.4510))
        #expect(palette.secondary == ArtworkColor(red: 0.7255, green: 0.8392, blue: 0.7608))
        #expect(palette.accent == ArtworkColor(red: 0.9569, green: 0.8745, blue: 0.6078))
    }

    @Test(arguments: [VinylDesign.bloom, .rhapsody, .carnival])
    func artisticColorsPreserveHueAndExpandSaturation(design: VinylDesign) throws {
        let palette = try #require(VinylDesignPalette.resolve(warm, design: design))
        // Reference values independently checked with Python's colorsys HLS conversion.
        close(palette.primary, to: (0.897309, 0.245288, 0.154759))
        close(palette.secondary, to: (0.278363, 0.910809, 0.474716))
        close(palette.accent, to: (0.919718, 0.766233, 0.269454))
        #expect(palette.paper == ArtworkColor(red: 0.9569, green: 0.8745, blue: 0.6078))
    }

    @Test(arguments: [VinylDesign.bloom, .rhapsody, .carnival])
    func neutralSlotsStayNeutral(design: VinylDesign) throws {
        let white = ArtworkColor(red: 1, green: 1, blue: 1)
        let gray = ArtworkColor(red: 0.5, green: 0.5, blue: 0.5)
        let result = try #require(VinylDesignPalette.resolve(.marble(white, gray, ArtworkColor(red: 1, green: 0, blue: 0)), design: design))
        #expect(result.primary == white)
        #expect(result.secondary == gray)
    }

    @Test(arguments: [VinylDesign.bloom, .rhapsody, .carnival])
    func repeatedSlotsRemainFiniteAndRelated(design: VinylDesign) throws {
        let red = ArtworkColor(red: 1, green: 0, blue: 0)
        let result = try #require(VinylDesignPalette.resolve(.marble(red, red, red), design: design))
        #expect(result.primary == result.secondary && result.primary == result.accent)
        #expect(result.primary.red > result.primary.green)
        #expect(result.primary.green == result.primary.blue)
        for channel in [result.primary.red, result.primary.green, result.primary.blue] {
            #expect(channel.isFinite && (0...1).contains(channel))
        }
    }

    private func close(_ color: ArtworkColor, to expected: (Double, Double, Double)) {
        #expect(abs(color.red - expected.0) < 0.001)
        #expect(abs(color.green - expected.1) < 0.001)
        #expect(abs(color.blue - expected.2) < 0.001)
    }
}
