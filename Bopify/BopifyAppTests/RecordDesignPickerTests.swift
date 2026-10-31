import AppKit
import SwiftUI
import Testing

@MainActor @Suite("Record material chooser", .serialized)
struct RecordDesignPickerTests {
    @Test func focusAndActivationPersistOnlyTheMaterial() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("carnival", forKey: VinylDesign.preferenceKey)
        let model = RecordDesignPickerModel(defaults: defaults)
        model.move(.left)
        #expect(model.focused == .classic)
        model.move(.right)
        model.move(.down)
        #expect(model.focused == .glass)
        #expect(defaults.string(forKey: RecordDesign.preferenceKey) == nil)
        model.activate()
        #expect(defaults.string(forKey: RecordDesign.preferenceKey) == "glass")
        #expect(defaults.string(forKey: VinylDesign.preferenceKey) == "carnival")
        model.move(.right)
        model.move(.right)
        model.move(.up)
        #expect(model.focused == .nacre)
    }

    @Test func selectionIsAccessibleImmediateAndPersistsAcrossRecreation() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("unknown", forKey: RecordDesign.preferenceKey)
        var mounted = showPicker(defaults: defaults)
        defer { mounted.close() }
        try await Task.sleep(for: .milliseconds(150))
        #expect(try element("record.design.classic", in: window()).value == "Selected")
        #expect(try element("record.design.glass", in: window()).label == "Glass")
        #expect(try element("record.design.glass", in: window()).press())
        try await Task.sleep(for: .milliseconds(80))
        #expect(defaults.string(forKey: RecordDesign.preferenceKey) == "glass")
        let selected = try RecordDesign.allCases.filter { try element($0.nameKey, in: window()).value == "Selected" }
        #expect(selected == [.glass])
        #expect(try window().isVisible)
        mounted.close()
        mounted = showPicker(defaults: defaults)
        try await Task.sleep(for: .milliseconds(100))
        #expect(try element("record.design.glass", in: window()).value == "Selected")
    }

    @Test func nativeKeysActivateAndDismissAndWindowIsReused() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = RecordDesignWindowController(defaults: defaults)
        controller.show()
        defer { controller.close() }
        let first = try window()
        func key(_ code: UInt16, _ text: String) throws {
            first.sendEvent(try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: first.windowNumber, context: nil,
                characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)))
        }
        try key(124, "\u{f703}")
        #expect(defaults.string(forKey: RecordDesign.preferenceKey) == nil)
        try key(49, " ")
        #expect(defaults.string(forKey: RecordDesign.preferenceKey) == "glass")
        try key(124, "\u{f703}")
        try key(36, "\r")
        #expect(defaults.string(forKey: RecordDesign.preferenceKey) == "nacre")
        try key(53, "\u{1b}")
        #expect(!first.isVisible)
        controller.show()
        #expect(try window() === first)
    }

    @Test(.enabled("Requires native screen capture") { @MainActor in VinylRenderingFixture.canCapture })
    func nativeChooserHasStaticMaterialPreviews() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("glass", forKey: RecordDesign.preferenceKey)
        let controller = RecordDesignWindowController(defaults: defaults)
        controller.show()
        defer { controller.close() }
        let image = try await VinylRenderingFixture.capture(window(),
            to: VinylRenderingFixture.directory.appendingPathComponent("record-design-chooser.png"))
        #expect(image.pixelsWide >= 540)
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        _ = NSApplication.shared
        let suite = "bopify-record-picker-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    private func window() throws -> NSWindow {
        try #require(NSApp.windows.first { $0.identifier?.rawValue == "record-design" && $0.isVisible })
    }

    // XCTest's background host needs accessibility enabled to materialize SwiftUI's virtual nodes.
    private func showPicker(defaults: UserDefaults) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 300, y: 300, width: 540, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier("record-design")
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: RecordDesignPicker(model: RecordDesignPickerModel(defaults: defaults))
            .defaultAppStorage(defaults).environment(\.accessibilityEnabled, true))
        window.makeKeyAndOrderFront(nil)
        return window
    }

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
        return ChoiceElement(object: try #require(search(root), "Missing material choice \(id)"))
    }
}
