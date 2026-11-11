import AppKit
import SwiftUI
import CoreText
import Testing

@MainActor @Suite("Appearance native presentation", .serialized)
struct RecordAppearanceRenderingTests {
    @Test func approvedImagesFontsAndLicensesAreBundled() throws {
        RecordAppearanceResources.prepare()
        let deck = try #require(RecordAppearanceResources.deck)
        let cloth = try #require(RecordAppearanceResources.corduroy)
        let d = try #require(deck.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let c = try #require(cloth.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let clothPixels = try #require(RecordAppearanceResources.corduroyPixels)
        #expect(clothPixels.width == c.width && clothPixels.height == c.height)
        #expect(d.alphaInfo != .none)
        for name in ["ManropeV5-Regular", "ManropeV5-Medium", "ManropeV5-SemiBold", "IBMPlexSansCond-Medium"] {
            #expect(CTFontCopyPostScriptName(CTFontCreateWithName(name as CFString, 12, nil)) as String == name)
        }
        for name in ["Allura-OFL", "IBMPlexSansCondensed-OFL"] {
            let url = try #require(RecordAppearanceResources.bundle.url(forResource: name, withExtension: "txt"))
            #expect(try String(contentsOf: url, encoding: .utf8).contains("SIL OPEN FONT LICENSE"))
        }
        let licenseURL = try #require(RecordAppearanceResources.bundle.url(forResource: "ManropeV5-License", withExtension: "txt"))
        let license = try String(contentsOf: licenseURL, encoding: .utf8)
        #expect(license.contains("Manrope V5 by Mikhail Sharanda"))
        #expect(license.contains("You may embed this font in websites, apps, or software."))
        #expect(RecordAppearanceResources.image(named: "missing-appearance-image") == nil)
    }
    @Test func longNamesWrapWithoutLeavingBounds() {
        let sizes = [CGSize(width: 220, height: 32), CGSize(width: 170, height: 32), CGSize(width: 80, height: 32)]
        let frames = RecordAppearanceOptionLayout.frames(sizes: sizes, width: 300)
        #expect(frames.count == 3)
        #expect(frames.allSatisfy { $0.minX >= 0 && $0.maxX <= 300 })
        #expect(frames[1].minY > frames[0].minY)
        #expect(frames[2].minY == frames[1].minY)
    }
    @Test(arguments: [CGSize(width: 180, height: 80), CGSize(width: 80, height: 180)], [CGFloat(1), CGFloat(2)])
    func corduroyFillsWindowWithOneProportionallyScaledImage(_ size: CGSize, _ scale: CGFloat) throws {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 120, pixelsHigh: 80,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 480, bitsPerPixel: 32))
        let bytes = try #require(bitmap.bitmapData)
        for y in 0..<80 {
            for x in 0..<120 {
                let offset = y * bitmap.bytesPerRow + x * 4
                bytes[offset] = UInt8(x * 255 / 119)
                bytes[offset + 1] = UInt8(y * 255 / 79)
                bytes[offset + 2] = 255
                bytes[offset + 3] = 255
            }
        }
        let pixels = try #require(bitmap.cgImage?.copy(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!))
        let renderer = ImageRenderer(content: RecordAppearanceCloth(image: pixels)
            .frame(width: size.width, height: size.height))
        renderer.scale = scale
        let capture = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        #expect(capture.bitsPerSample == 8 && capture.samplesPerPixel == 4)
        let fit = max(size.width / 120, size.height / 80)
        let crop = CGPoint(x: (120 * fit - size.width) / 2, y: (80 * fit - size.height) / 2)
        for fraction in [CGFloat(0.05), 0.25, 0.5, 0.75, 0.95] {
            let x = Int(size.width * scale * fraction), y = Int(size.height * scale * fraction)
            var pixel = [UInt](repeating: 0, count: capture.samplesPerPixel)
            capture.getPixel(&pixel, atX: x, y: y)
            let sourceX = ((CGFloat(x) + 0.5) / scale + crop.x) / fit
            let sourceY = ((CGFloat(y) + 0.5) / scale + crop.y) / fit
            #expect(abs(CGFloat(pixel[0]) / 255 - sourceX / 120 * 0.86) < 0.04)
            #expect(abs(CGFloat(pixel[1]) / 255 - sourceY / 80 * 0.86) < 0.04)
            #expect(abs(CGFloat(pixel[2]) / 255 - 0.86) < 0.02, "The image must cover the entire window")
        }
    }
    @Test(arguments: [CGFloat(760), CGFloat(900)])
    func allNineChoicesExposeIndependentSelections(_ width: CGFloat) async throws {
        let suite = "appearance-render-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("glass", forKey: RecordDesign.preferenceKey)
        defaults.set("bloom", forKey: VinylDesign.preferenceKey)
        let model = RecordAppearancePickerModel(defaults: defaults)
        let window = mount(model, width: width)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(180))
        for family in RecordAppearanceFamily.allCases {
            var selected = 0
            for choice in RecordAppearanceChoice.choices(in: family) {
                let node = try AppearanceTestAccessibility.element(choice.nameKey, in: window)
                if node.value == "Selected" { selected += 1 }
                #expect(node.object.accessibilityRole?() == .button)
            }
            #expect(selected == 1)
        }
    }
    private func mount(_ model: RecordAppearancePickerModel, width: CGFloat) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: width, height: width == 900 ? 655 : 631),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: RecordAppearancePicker(model: model).environment(\.accessibilityEnabled, true))
        window.orderFrontRegardless()
        return window
    }
}

@MainActor enum AppearanceTestAccessibility {
    struct Element {
        let object: AnyObject
        var value: String? {
            guard let node = object as? NSObject, node.responds(to: NSSelectorFromString("accessibilityValue")) else { return nil }
            return node.perform(NSSelectorFromString("accessibilityValue"))?.takeUnretainedValue() as? String
        }
        func press() -> Bool { object.accessibilityPerformPress?() ?? false }
    }
    static func element(_ id: String, in root: Any) throws -> Element {
        var visited = Set<ObjectIdentifier>()
        func search(_ object: Any) -> AnyObject? {
            let node = object as AnyObject
            guard visited.insert(ObjectIdentifier(node)).inserted else { return nil }
            if node.accessibilityIdentifier?() == id { return node }
            // Scroll areas expose their document's semantic nodes through AXContents.
            let children = (node.accessibilityChildren?() ?? []) + (node.accessibilityContents?() ?? [])
            for child in children {
                if let found = search(child) { return found }
            }
            if let view = object as? NSView {
                for child in view.subviews { if let found = search(child) { return found } }
            }
            return nil
        }
        return Element(object: try #require(search(root), "Missing appearance control \(id)"))
    }
}
