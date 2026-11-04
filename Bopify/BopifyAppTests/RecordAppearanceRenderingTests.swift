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
    @Test(.enabled("Requires native screen capture") { @MainActor in VinylRenderingFixture.canCapture },
          arguments: [CGFloat(760), CGFloat(900)])
    func nativeIdealAndCompact(_ width: CGFloat) async throws {
        let suite = "appearance-capture-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("glass", forKey: RecordDesign.preferenceKey)
        defaults.set("bloom", forKey: VinylDesign.preferenceKey)
        let model = RecordAppearancePickerModel(defaults: defaults)
        model.isMotionPaused = true
        let window = mount(model, width: width)
        defer { window.close() }
        let image = try await VinylRenderingFixture.capture(window,
            to: VinylRenderingFixture.directory.appendingPathComponent("appearance-\(Int(width)).png"))
        #expect(image.pixelsWide >= Int(width))
        #expect(model.selectedMaterial == .glass && model.selectedPattern == .bloom)
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
            for child in node.accessibilityChildren?() ?? [] {
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
