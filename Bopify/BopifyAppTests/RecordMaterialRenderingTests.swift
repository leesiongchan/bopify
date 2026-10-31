import AppKit
import SwiftUI
import Testing
import Metal
import Observation
import BopifyPlayback

@MainActor @Suite("Record material native rendering", .serialized)
struct RecordMaterialRenderingTests {
    @Test(.enabled("Requires native screen capture") { @MainActor in VinylRenderingFixture.canCapture })
    func mountedGlassRespondsToTransparencyChanges() async throws {
        let state = MountedRecordState()
        let window = mountedWindow(state)
        defer { window.close() }
        func snapshot(_ name: String, background: Color) async throws -> NSBitmapImageRep {
            state.background = background
            return try await VinylRenderingFixture.capture(window,
                to: VinylRenderingFixture.directory.appendingPathComponent("record-mounted-\(name).png"))
        }
        let clearDark = try await snapshot("clear-dark", background: .black)
        let clearLight = try await snapshot("clear-light", background: .white)
        #expect(VinylRenderingFixture.differingAnnulusFraction(clearDark, clearLight) > 0.5)
        state.opaque = true
        let opaqueDark = try await snapshot("opaque-dark", background: .black)
        let opaqueLight = try await snapshot("opaque-light", background: .white)
        #expect(VinylRenderingFixture.differingAnnulusFraction(opaqueDark, opaqueLight) < 0.01)
        try assertLabel(opaqueLight, matches: clearLight)
        state.opaque = false
        let restored = try await snapshot("restored", background: .white)
        #expect(VinylRenderingFixture.differingAnnulusFraction(clearLight, restored) == 0)
    }

    @Test(.enabled("Requires native screen capture") { @MainActor in VinylRenderingFixture.canCapture })
    func mountedMotionPausesAndResumesWithoutChangingTheMaterial() async throws {
        let state = MountedRecordState(moving: true)
        let window = mountedWindow(state)
        defer { window.close() }
        func snapshot(_ name: String) async throws -> NSBitmapImageRep {
            try await VinylRenderingFixture.capture(window,
                to: VinylRenderingFixture.directory.appendingPathComponent("record-motion-\(name).png"))
        }
        let first = try await snapshot("first")
        try await Task.sleep(for: .milliseconds(450))
        let moving = try await snapshot("moving")
        #expect(labelDifference(first, moving) > 0.03)
        state.reduced = true
        let paused = try await snapshot("paused")
        try await Task.sleep(for: .milliseconds(450))
        let still = try await snapshot("still")
        #expect(labelDifference(paused, still) < 0.01)
        state.reduced = false
        try await Task.sleep(for: .milliseconds(450))
        let resumed = try await snapshot("resumed")
        #expect(labelDifference(still, resumed) > 0.03)
    }

    @Test(.enabled("Requires native screen capture") { @MainActor in VinylRenderingFixture.canCapture })
    func glassSmokeIsContinuousAcrossTheAngularBranchCut() async throws {
        let image = try await VinylRenderingFixture.capture(
            VinylPressingView(seed: 42, palette: .neutral, recordDesign: .glass, diameter: 360),
            size: CGSize(width: 360, height: 360),
            to: VinylRenderingFixture.directory.appendingPathComponent("record-glass-seam.png"), background: .white)
        var delta = 0.0, count = 0.0
        for x in stride(from: image.pixelsWide / 6, to: image.pixelsWide / 3, by: 3) {
            let upper = try #require(image.colorAt(x: x, y: image.pixelsHigh / 2 - 1)?.usingColorSpace(.deviceRGB))
            let lower = try #require(image.colorAt(x: x, y: image.pixelsHigh / 2 + 1)?.usingColorSpace(.deviceRGB))
            delta += max(abs(upper.redComponent - lower.redComponent), abs(upper.greenComponent - lower.greenComponent),
                         abs(upper.blueComponent - lower.blueComponent))
            count += 1
        }
        #expect(delta / count < 0.025, "Organic smoke must not jump across atan2's branch cut")
    }

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

    private func mountedWindow(_ state: MountedRecordState) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 300, y: 300, width: 182, height: 182),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.contentView = NSHostingView(rootView: MountedRecordScene(state: state))
        window.orderFrontRegardless()
        return window
    }

    private func labelDifference(_ lhs: NSBitmapImageRep, _ rhs: NSBitmapImageRep) -> Double {
        var changed = 0.0, total = 0.0
        for y in stride(from: 0, to: lhs.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: lhs.pixelsWide, by: 2) {
                let r = hypot(Double(x) / Double(lhs.pixelsWide) * 2 - 1, Double(y) / Double(lhs.pixelsHigh) * 2 - 1)
                guard (0.08...0.35).contains(r), let a = lhs.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      let b = rhs.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                total += 1
                if abs(a.redComponent - b.redComponent) > 8.0 / 255 { changed += 1 }
            }
        }
        return total == 0 ? 0 : changed / total
    }
}

private final class RecordMaterialTestBundle: NSObject {}

@MainActor @Observable private final class MountedRecordState {
    var background = Color.white
    var opaque = false
    var reduced = false
    let moving: Bool
    let rotation: RecordRotation
    let image: NSImage

    init(moving: Bool = false) {
        self.moving = moving
        var motor = RecordRotation()
        motor.setRunning(true, at: ProcessInfo.processInfo.systemUptime - 1)
        rotation = motor
        image = NSImage(size: NSSize(width: 80, height: 80), flipped: false) { rect in
            NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).setFill(); rect.fill()
            if moving { NSColor(white: 0.8, alpha: 1).setFill(); CGRect(x: 40, y: 0, width: 40, height: 80).fill() }
            return true
        }
    }
}

private struct MountedRecordScene: View {
    let state: MountedRecordState
    var body: some View {
        VinylRecordView(image: Image(nsImage: state.image), occurrenceID: "mounted", direction: .fade,
                        diameter: 182, isMoving: state.moving, isVisible: true, rotation: state.rotation,
                        pressingSeed: 42, palette: .neutral, recordDesign: .glass,
                        reduceTransparencyOverride: state.opaque, rotationOverride: state.moving ? nil : 0,
                        reduceMotionOverride: state.reduced)
            .background(state.background)
    }
}
