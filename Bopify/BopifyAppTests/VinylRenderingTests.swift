import AppKit
import SwiftUI
import Testing
import Metal
import CoreGraphics
import BopifyPlayback

@MainActor @Suite("Vinyl native rendering", .serialized)
struct VinylRenderingTests {
    @Test(.enabled("Requires screen capture") { CGPreflightScreenCaptureAccess() })
    func existingPressingsHaveNativeCaptures() async throws {
        for (name, palette) in [("warm", VinylRenderingFixture.warm), ("cool", VinylRenderingFixture.cool), ("muted", .neutral)] {
            let bitmap = try await VinylRenderingFixture.capture(
                VinylPressingView(seed: 42, palette: palette, diameter: 182),
                size: CGSize(width: 182, height: 182),
                to: VinylRenderingFixture.directory.appendingPathComponent("original-\(name).png"))
            #expect(bitmap.pixelsWide >= 182)
        }
    }

    @Test func contourFunctionIsAvailable() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try device.makeDefaultLibrary(bundle: Bundle(for: VinylTestBundle.self))
        #expect(library.functionNames.contains("vinylContours"))
    }

    @Test func artisticFunctionsAreAvailable() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try device.makeDefaultLibrary(bundle: Bundle(for: VinylTestBundle.self))
        for name in ["vinylBloom", "vinylRhapsody", "vinylCarnival"] {
            #expect(library.functionNames.contains(name))
        }
    }

    @Test(.enabled("Requires screen capture") { CGPreflightScreenCaptureAccess() })
    func artisticStylesRenderDistinctly() async throws {
        let images = try await [VinylDesign.bloom, .rhapsody, .carnival].asyncImages()
        for i in 0..<images.count {
            for j in (i + 1)..<images.count {
                #expect(VinylRenderingFixture.differingAnnulusFraction(images[i], images[j]) > 0.10)
            }
        }
    }

    @Test(.enabled("Requires screen capture") { CGPreflightScreenCaptureAccess() })
    func artisticStylesFollowCoverHues() async throws {
        for design in [VinylDesign.bloom, .rhapsody, .carnival] {
            let warm = try await capture(design, palette: VinylRenderingFixture.warm, name: "warm")
            let cool = try await capture(design, palette: VinylRenderingFixture.cool, name: "cool")
            #expect(VinylRenderingFixture.differingAnnulusFraction(warm, cool) > 0.10)
        }
    }

    @Test(.enabled("Requires screen capture") { CGPreflightScreenCaptureAccess() })
    func artisticStylesFillMostOfTheAnnulusWithColor() async throws {
        for design in [VinylDesign.bloom, .rhapsody, .carnival] {
            for diameter in [182.0, 118.0] {
                let image = try await capture(design, palette: VinylRenderingFixture.warm, name: "color-\(diameter)", diameter: diameter)
                #expect(VinylRenderingFixture.coloredAnnulusFraction(image) > 0.5)
            }
        }
    }

    @Test(.enabled("Requires screen capture") { CGPreflightScreenCaptureAccess() })
    func sameSeedAndPaletteRenderStably() async throws {
        for design in [VinylDesign.bloom, .rhapsody, .carnival] {
            let first = try await capture(design, palette: VinylRenderingFixture.warm, name: "stable1")
            let second = try await capture(design, palette: VinylRenderingFixture.warm, name: "stable2")
            #expect(VinylRenderingFixture.differingAnnulusFraction(first, second) == 0)
        }
    }

    @Test(.enabled("Requires screen capture") { CGPreflightScreenCaptureAccess() })
    func contourStylesRenderDistinctly() async throws {
        let images = try await [VinylDesign.undertow, .drift, .strata].asyncImages()
        for i in 0..<images.count {
            for j in (i + 1)..<images.count {
                #expect(VinylRenderingFixture.differingAnnulusFraction(images[i], images[j]) > 0.10)
            }
        }
    }

    @Test(.enabled("Requires screen capture") { CGPreflightScreenCaptureAccess() })
    func contoursFollowCoverColors() async throws {
        for design in [VinylDesign.undertow, .drift, .strata] {
            let warm = try await capture(design, palette: VinylRenderingFixture.warm, name: "warm")
            let cool = try await capture(design, palette: VinylRenderingFixture.cool, name: "cool")
            #expect(VinylRenderingFixture.differingAnnulusFraction(warm, cool) > 0.10)
        }
    }

    @Test(.enabled("Requires screen capture") { CGPreflightScreenCaptureAccess() })
    func allDesignsKeepTheMutedBaseline() async throws {
        let baseline = try await capture(.original, palette: .neutral, name: "muted")
        for design in VinylDesign.allCases {
            let image = try await capture(design, palette: .neutral, name: "muted")
            #expect(VinylRenderingFixture.differingAnnulusFraction(baseline, image) == 0)
        }
    }

    @Test(.enabled("Requires screen capture") { CGPreflightScreenCaptureAccess() })
    func defaultDesignMatchesExplicitOriginal() async throws {
        let baseline = try await VinylRenderingFixture.capture(
            VinylPressingView(seed: 42, palette: VinylRenderingFixture.warm, diameter: 182),
            size: CGSize(width: 182, height: 182), to: VinylRenderingFixture.directory.appendingPathComponent("default.png"))
        let explicit = try await capture(.original, palette: VinylRenderingFixture.warm, name: "warm")
        #expect(VinylRenderingFixture.differingAnnulusFraction(baseline, explicit) == 0)
    }

    private func capture(_ design: VinylDesign, palette: ArtworkPalette, name: String, diameter: CGFloat = 182) async throws -> NSBitmapImageRep {
        try await VinylRenderingFixture.capture(VinylPressingView(seed: 42, palette: palette, design: design, diameter: diameter),
            size: CGSize(width: diameter, height: diameter),
            to: VinylRenderingFixture.directory.appendingPathComponent("\(design.rawValue)-\(name).png"))
    }
}

private final class VinylTestBundle: NSObject {}

private extension Array where Element == VinylDesign {
    @MainActor func asyncImages() async throws -> [NSBitmapImageRep] {
        var images: [NSBitmapImageRep] = []
        for design in self {
            images.append(try await VinylRenderingFixture.capture(
                VinylPressingView(seed: 42, palette: VinylRenderingFixture.warm, design: design, diameter: 182),
                size: CGSize(width: 182, height: 182),
                to: VinylRenderingFixture.directory.appendingPathComponent("\(design.rawValue)-warm.png")))
        }
        return images
    }
}
