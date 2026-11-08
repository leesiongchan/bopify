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
        #expect(d.width == 1509 && d.height == 1042)
        #expect(c.width == 1254 && c.height == 1254)
        let tile = try #require(RecordAppearanceResources.corduroyTile)
        #expect(tile.width > 1100 && tile.width < c.width && tile.height == c.height)
        #expect(d.alphaInfo != .none)
        for name in ["Allura-Regular", "IBMPlexSansCond-Medium"] {
            #expect(CTFontCopyPostScriptName(CTFontCreateWithName(name as CFString, 12, nil)) as String == name)
        }
        for name in ["Allura-OFL", "IBMPlexSansCondensed-OFL"] {
            let url = try #require(RecordAppearanceResources.bundle.url(forResource: name, withExtension: "txt"))
            #expect(try String(contentsOf: url, encoding: .utf8).contains("SIL OPEN FONT LICENSE"))
        }
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
    @Test func corduroyPreservesPixelsAndMatchesReflectedEdges() throws {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 16, bitsPerPixel: 32))
        let levels: [CGFloat] = [0.05, 0.85, 0.15, 0.95]
        let bytes = try #require(bitmap.bitmapData)
        for y in 0..<4 {
            for x in 0..<4 {
                let offset = y * bitmap.bytesPerRow + x * 4
                let level = UInt8((levels[x] * 255).rounded())
                bytes[offset] = level
                bytes[offset + 1] = level
                bytes[offset + 2] = level
                bytes[offset + 3] = 255
            }
        }
        let sample = NSImage(size: CGSize(width: 4, height: 4))
        sample.addRepresentation(bitmap)
        #expect(try #require(bitmap.colorAt(x: 1, y: 0)?.usingColorSpace(.deviceRGB)).redComponent > 0.8)
        let pixels = try #require(sample.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(pixels.width == 4)
        let renderer = ImageRenderer(content: RecordAppearanceCloth(image: pixels)
            .frame(width: 128, height: 64))
        renderer.scale = 2
        let capture = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        func value(_ x: Int) throws -> CGFloat {
            try #require(capture.colorAt(x: x, y: 8)?.usingColorSpace(.deviceRGB)).redComponent
        }
        let values = try (0..<8).map(value)
        #expect((values.max()! - values.min()!) > 0.65, "Fine fibres must keep their source contrast, without fractional rescaling")
        #expect(try value(0) < 0.1, "Anchor the texture at the viewport's leading edge")
        #expect(try abs(value(3) - value(4)) < 0.01, "Horizontal mirror boundary must match")
        #expect(try abs(value(7) - value(8)) < 0.01, "Alternate mirror boundary must match")
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
