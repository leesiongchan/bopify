import AppKit
import SwiftUI
import Testing

@MainActor @Suite("Vinyl chooser", .serialized)
struct VinylDesignPickerTests {
    @Test func nativeNavigationClampsAtBottomAndActivatesTheFocusedDesign() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = VinylDesignPickerModel(defaults: defaults)
        model.move(.down)
        model.move(.down)
        model.move(.down)
        #expect(model.focused == .bloom)
        #expect(defaults.string(forKey: VinylDesign.preferenceKey) == nil)
        model.activate()
        #expect(defaults.string(forKey: VinylDesign.preferenceKey) == "bloom")
        model.move(.right)
        model.move(.up)
        #expect(model.focused == .undertow)
        model.move(.right)
        model.move(.down)
        model.move(.right)
        #expect(model.focused == .carnival)
        model.move(.up)
        #expect(model.focused == .strata)
    }
    @Test func windowReopensAsOneInstance() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = VinylDesignWindowController(defaults: defaults)
        defer { controller.close() }
        controller.show()
        let first = try window()
        controller.show()
        #expect(try window() === first)
        controller.close()
        controller.show()
        #expect(try window() === first)
    }

    @Test func selectionIsImmediateAndPersistsAcrossWindowRecreation() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var mounted = showPicker(defaults: defaults)
        defer { mounted.close() }
        try await Task.sleep(for: .milliseconds(150))
        let bloom = try element("vinyl.design.bloom", in: window())
        #expect(bloom.press())
        try await Task.sleep(for: .milliseconds(50))
        #expect(defaults.string(forKey: VinylDesign.preferenceKey) == "bloom")
        #expect(try window().isVisible)
        #expect(try element("vinyl.design.bloom", in: window()).value == "Selected")
        mounted.close()
        mounted = showPicker(defaults: defaults)
        try await Task.sleep(for: .milliseconds(100))
        #expect(try element("vinyl.design.bloom", in: window()).value == "Selected")
    }

    @Test(arguments: ["removed-style", "drift"])
    func invalidPreferenceSelectsMarble(rawValue: String) async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(rawValue, forKey: VinylDesign.preferenceKey)
        let mounted = showPicker(defaults: defaults)
        defer { mounted.close() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(try element("vinyl.design.original", in: window()).value == "Selected")
        #expect(try element("vinyl.design.original", in: window()).label == "Marble")
        #expect(try element("vinyl.design.carnival", in: window()).value == "Not selected")
    }

    @Test func accessibilityExposesOneSelectedDesign() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let mounted = showPicker(defaults: defaults)
        defer { mounted.close() }
        try await Task.sleep(for: .milliseconds(100))
        let window = try window()
        let carnival = try element("vinyl.design.carnival", in: window)
        #expect(carnival.label == "Carnival")
        #expect(carnival.press())
        try await Task.sleep(for: .milliseconds(50))
        let selected = try VinylDesign.allCases.filter {
            try element($0.nameKey, in: window).value == "Selected"
        }
        #expect(selected == [.carnival])
        #expect(defaults.string(forKey: VinylDesign.preferenceKey) == "carnival")
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        _ = NSApplication.shared
        let suite = "bopify-vinyl-picker-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    private func showPicker(defaults: UserDefaults) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 300, y: 300, width: 540, height: 587),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier("vinyl-design")
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: VinylDesignPicker(model: VinylDesignPickerModel(defaults: defaults), onClose: { [weak window] in window?.close() })
            .defaultAppStorage(defaults).environment(\.accessibilityEnabled, true))
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func window() throws -> NSWindow {
        try #require(NSApp.windows.first { $0.identifier?.rawValue == "vinyl-design" && $0.isVisible })
    }

    // SwiftUI's virtual nodes implement the Objective-C accessors without full protocol conformance.
    private struct ChoiceElement {
        let object: AnyObject
        var value: String? {
            guard let object = object as? NSObject,
                  object.responds(to: NSSelectorFromString("accessibilityValue")) else { return nil }
            return object.perform(NSSelectorFromString("accessibilityValue"))?.takeUnretainedValue() as? String
        }
        var label: String? { object.accessibilityLabel?() }
        func press() -> Bool { object.accessibilityPerformPress?() ?? false }
    }

    private func element(_ id: String, in root: Any) throws -> ChoiceElement {
        var visited = Set<ObjectIdentifier>()
        func search(_ object: Any) -> AnyObject? {
            let accessible = object as AnyObject
            guard visited.insert(ObjectIdentifier(accessible)).inserted else { return nil }
            if accessible.accessibilityIdentifier?() == id { return accessible }
            for child in accessible.accessibilityChildren?() ?? [] {
                if let found = search(child) { return found }
            }
            if let view = object as? NSView {
                for child in view.subviews { if let found = search(child) { return found } }
            }
            return nil
        }
        return ChoiceElement(object: try #require(search(root), "Missing chooser control \(id)"))
    }
}
