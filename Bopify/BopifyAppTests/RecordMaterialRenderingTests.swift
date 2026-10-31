import AppKit
import SwiftUI
import Testing
import Metal
import BopifyPlayback

@MainActor @Suite("Record material native rendering", .serialized)
struct RecordMaterialRenderingTests {
    @Test func materialFunctionsAreAvailable() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try device.makeDefaultLibrary(bundle: Bundle(for: RecordMaterialTestBundle.self))
        #expect(library.functionNames.contains("recordGlass"))
        #expect(library.functionNames.contains("recordNacre"))
    }

    @Test(.enabled("Requires native screen capture") { @MainActor in VinylRenderingFixture.canCapture },
          arguments: [118.0, 182.0])
    func completeGlassRevealsBackgroundAndKeepsLabelOpaque(diameter: Double) async throws {
        let dark = try await capture(.glass, diameter: diameter, name: "dark")
        let light = try await capture(.glass, diameter: diameter, name: "light", background: .white)
        let reference = try await capture(.classic, diameter: diameter, name: "label-reference")
        #expect(VinylRenderingFixture.differingAnnulusFraction(dark, light) > 0.5)
        try assertLabel(dark, matches: reference)
        try assertLabel(light, matches: reference)
    }

    @Test(.enabled("Requires native screen capture") { @MainActor in VinylRenderingFixture.canCapture },
          arguments: [118.0, 182.0])
    func nacreIsOpaqueAndDistinctFromClassic(diameter: Double) async throws {
        let classic = try await capture(.classic, diameter: diameter, name: "classic")
        let dark = try await capture(.nacre, diameter: diameter, name: "dark")
        let light = try await capture(.nacre, diameter: diameter, name: "light", background: .white)
        #expect(VinylRenderingFixture.differingAnnulusFraction(dark, light) < 0.01)
        #expect(VinylRenderingFixture.differingAnnulusFraction(classic, dark) > 0.1)
        let glass = try await capture(.glass, diameter: diameter, name: "compare")
        #expect(VinylRenderingFixture.differingAnnulusFraction(glass, dark) > 0.1)
        try assertLabel(light, matches: classic)
    }

    @Test(.enabled("Requires native screen capture") { @MainActor in VinylRenderingFixture.canCapture })
    func reduceTransparencyMakesGlassOpaqueWithoutChangingLabel() async throws {
        let dark = try await capture(.glass, name: "accessible-dark", reduceTransparency: true)
        let light = try await capture(.glass, name: "accessible-light", background: .white, reduceTransparency: true)
        let reference = try await capture(.classic, name: "accessible-label-reference")
        #expect(VinylRenderingFixture.differingAnnulusFraction(dark, light) < 0.01)
        try assertLabel(light, matches: reference)
    }

    @Test(.enabled("Requires native screen capture") { @MainActor in VinylRenderingFixture.canCapture })
    func sameSeedAndMaterialRenderStably() async throws {
        for design in [RecordDesign.glass, .nacre] {
            let first = try await capture(design, name: "stable-1")
            let second = try await capture(design, name: "stable-2")
            #expect(VinylRenderingFixture.differingAnnulusFraction(first, second) == 0)
        }
    }

    @Test(.enabled("Requires native screen capture") { @MainActor in VinylRenderingFixture.canCapture })
    func colorfulStylesIgnoreMutedMaterial() async throws {
        for style in VinylDesign.allCases {
            let baseline = try await pressing(.classic, style: style)
            for material in [RecordDesign.glass, .nacre] {
                let image = try await pressing(material, style: style)
                #expect(VinylRenderingFixture.differingAnnulusFraction(baseline, image) == 0)
            }
        }
    }

    private func pressing(_ material: RecordDesign, style: VinylDesign) async throws -> NSBitmapImageRep {
        try await VinylRenderingFixture.capture(
            VinylPressingView(seed: 42, palette: VinylRenderingFixture.warm, design: style, recordDesign: material, diameter: 182),
            size: CGSize(width: 182, height: 182),
            to: VinylRenderingFixture.directory.appendingPathComponent("record-colorful-\(style.rawValue)-\(material.rawValue).png"))
    }

    private func capture(_ design: RecordDesign, diameter: Double = 182, name: String,
                         background: Color = .black, reduceTransparency: Bool = false) async throws -> NSBitmapImageRep {
        let image = NSImage(size: NSSize(width: 80, height: 80), flipped: false) { rect in
            NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).setFill()
            rect.fill()
            return true
        }
        return try await VinylRenderingFixture.capture(
            VinylRecordView(image: Image(nsImage: image), occurrenceID: "material", direction: .fade,
                            diameter: diameter, isMoving: false, isVisible: true, rotation: RecordRotation(),
                            pressingSeed: 42, palette: .neutral, recordDesign: design,
                            reduceTransparencyOverride: reduceTransparency, rotationOverride: 0),
            size: CGSize(width: diameter, height: diameter),
            to: VinylRenderingFixture.directory.appendingPathComponent("record-\(design.rawValue)-\(Int(diameter))-\(name).png"),
            background: background)
    }

    private func assertLabel(_ bitmap: NSBitmapImageRep, matches reference: NSBitmapImageRep) throws {
        for side in [-1.0, 1.0] {
            let color = try #require(bitmap.colorAt(x: Int(Double(bitmap.pixelsWide) * (0.5 + side * 0.10)),
                                                   y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
            let expected = try #require(reference.colorAt(x: Int(Double(reference.pixelsWide) * (0.5 + side * 0.10)),
                                                          y: reference.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
            #expect(expected.redComponent > 0.9 && expected.greenComponent < 0.2 && expected.blueComponent < 0.1)
            #expect(max(abs(color.redComponent - expected.redComponent), abs(color.greenComponent - expected.greenComponent),
                        abs(color.blueComponent - expected.blueComponent)) < 8.0 / 255)
        }
    }
}

private final class RecordMaterialTestBundle: NSObject {}
