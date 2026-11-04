import AppKit
import Testing

@MainActor @Suite("Unified appearance window", .serialized)
struct RecordAppearancePickerTests {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "appearance-window-\(UUID())")! }
    private func window() throws -> NSWindow {
        try #require(NSApp.windows.first { $0.identifier?.rawValue == "record-appearance" && $0.isVisible })
    }
    private func key(_ code: UInt16, _ text: String = "", modifiers: NSEvent.ModifierFlags = [], in window: NSWindow) throws {
        window.sendEvent(try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)))
    }
    @Test func oneWindowIsReused() throws {
        let c = RecordAppearanceWindowController(defaults: defaults())
        c.show(); defer { c.close() }
        let first = try window()
        c.show()
        #expect(try window() === first)
        c.close(); c.show()
        #expect(try window() === first)
    }
    @Test func savedChoicesAppearOnOpenWithoutWrites() async throws {
        let d = defaults()
        d.set("unknown", forKey: RecordDesign.preferenceKey)
        d.set("bloom", forKey: VinylDesign.preferenceKey)
        let c = RecordAppearanceWindowController(defaults: d)
        c.show(); defer { c.close() }
        try await Task.sleep(for: .milliseconds(150))
        #expect(try AppearanceTestAccessibility.element("record.design.classic", in: window()).value == "Selected")
        #expect(try AppearanceTestAccessibility.element("vinyl.design.bloom", in: window()).value == "Selected")
        #expect(d.string(forKey: RecordDesign.preferenceKey) == "unknown")
    }
    @Test func realKeysFocusBeforeSaving() throws {
        let d = defaults(), c = RecordAppearanceWindowController(defaults: d)
        c.show(); defer { c.close() }
        let w = try window()
        try key(124, "\u{f703}", in: w)
        #expect(c.model.focused == .choice(.material(.glass)))
        #expect(d.string(forKey: RecordDesign.preferenceKey) == nil)
        try key(125, "\u{f701}", in: w)
        #expect(c.model.focused == .choice(.pattern(.undertow)))
        try key(115, "\u{f729}", in: w)
        #expect(c.model.focused == .choice(.pattern(.original)))
        try key(119, "\u{f72b}", in: w)
        try key(36, "\r", in: w)
        #expect(d.string(forKey: VinylDesign.preferenceKey) == "carnival")
        try key(126, "\u{f700}", in: w)
        try key(49, " ", in: w)
        #expect(d.string(forKey: RecordDesign.preferenceKey) == "nacre")
    }
    @Test func motionButtonSpaceDoesNotActivateLastChoice() async throws {
        let d = defaults(), c = RecordAppearanceWindowController(defaults: d)
        c.show(); defer { c.close() }
        try await Task.sleep(for: .milliseconds(150))
        c.model.focused = .motion
        try await Task.sleep(for: .milliseconds(100))
        #expect(c.model.focused == .motion)
        try key(49, " ", in: window())
        #expect(c.model.isMotionPaused)
        #expect(d.string(forKey: RecordDesign.preferenceKey) == nil)
        #expect(d.string(forKey: VinylDesign.preferenceKey) == nil)
    }
    @Test func modifiedKeysUseNormalWindowRouting() throws {
        let d = defaults(), c = RecordAppearanceWindowController(defaults: d)
        c.show(); defer { c.close() }
        try key(124, "\u{f703}", modifiers: .command, in: window())
        try key(49, " ", modifiers: .option, in: window())
        #expect(d.string(forKey: RecordDesign.preferenceKey) == nil)
        #expect(d.string(forKey: VinylDesign.preferenceKey) == nil)
    }
    @Test func reducedMotionKeysSkipAndCannotActivateMotion() async throws {
        let d = defaults()
        var reduceMotion = true
        let c = RecordAppearanceWindowController(defaults: d, reduceMotion: { reduceMotion })
        c.show(); defer { c.close() }
        let w = try window()
        try await Task.sleep(for: .milliseconds(150))
        c.model.focused = .motion
        try key(49, " ", in: w)
        #expect(!c.model.isMotionPaused)
        try key(36, "\r", in: w)
        #expect(!c.model.isMotionPaused)
        c.model.focused = .choice(.pattern(.carnival))
        try key(48, "\t", in: w)
        #expect(c.model.focused == .choice(.material(.classic)))
        try key(48, "\t", modifiers: .shift, in: w)
        #expect(c.model.focused == .choice(.pattern(.carnival)))
        #expect(d.string(forKey: RecordDesign.preferenceKey) == nil)
        #expect(d.string(forKey: VinylDesign.preferenceKey) == nil)
        reduceMotion = false
        try key(48, "\t", in: w)
        #expect(c.model.focused == .motion)
        try key(49, " ", in: w)
        #expect(c.model.isMotionPaused)
    }
    @Test func escapeClosesAndRetainsChoices() throws {
        let d = defaults(), c = RecordAppearanceWindowController(defaults: d)
        c.show(); defer { c.close() }
        let w = try window()
        try key(124, in: w); try key(36, "\r", in: w)
        try key(53, "\u{1b}", in: w)
        #expect(!w.isVisible && !c.model.isPreviewVisible)
        #expect(d.string(forKey: RecordDesign.preferenceKey) == "glass")
    }
    @Test func closedDefaultsChangesAppearOnReopen() throws {
        let d = defaults(), c = RecordAppearanceWindowController(defaults: d)
        c.show(); c.close()
        d.set("nacre", forKey: RecordDesign.preferenceKey)
        d.set("rhapsody", forKey: VinylDesign.preferenceKey)
        c.show(); defer { c.close() }
        #expect(c.model.selectedMaterial == .nacre && c.model.selectedPattern == .rhapsody)
    }
    @Test func closeDuringCrossingReopensSettled() async throws {
        let d = defaults(), c = RecordAppearanceWindowController(defaults: d)
        c.show(); defer { c.close() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(try AppearanceTestAccessibility.element("record.design.glass", in: window()).press())
        try await Task.sleep(for: .milliseconds(650))
        c.close()
        #expect(!c.model.isPreviewVisible)
        c.show()
        #expect(c.model.selectedMaterial == .glass)
    }
    @Test(.enabled("Requires native screen capture") { @MainActor in VinylRenderingFixture.canCapture },
          arguments: [CGFloat(760), CGFloat(900)])
    func nativeWindowAndSimultaneousUppermostExchanges(_ width: CGFloat) async throws {
        let d = defaults()
        d.set("glass", forKey: RecordDesign.preferenceKey)
        d.set("bloom", forKey: VinylDesign.preferenceKey)
        let c = RecordAppearanceWindowController(defaults: d)
        c.model.isMotionPaused = true
        c.show(); defer { c.close() }
        let w = try window()
        w.setFrame(CGRect(origin: w.frame.origin, size: CGSize(width: width, height: width == 900 ? 655 : 631)), display: true)
        w.orderFrontRegardless()
        // XCTest can be on an inactive Space even when its backing window is capturable.
        // The foreground host verifies actual AppKit visibility; this fixture drives rendering.
        try await Task.sleep(for: .milliseconds(80))
        c.model.isPreviewVisible = true
        let prefix = "appearance-native-\(Int(width))"
        func capture(_ stage: String) async throws -> NSBitmapImageRep {
            try await VinylRenderingFixture.capture(w, to: VinylRenderingFixture.directory.appendingPathComponent("\(prefix)-\(stage).png"))
        }
        let initial = try await capture("mounted")
        #expect(initial.pixelsWide >= Int(width))
        #expect(w.standardWindowButton(.closeButton)?.isHidden == false)
        c.model.select(.material(.classic))
        c.model.select(.pattern(.original))
        try await Task.sleep(for: .milliseconds(500))
        _ = try await capture("crossing")
        try await Task.sleep(for: .milliseconds(1400))
        let stopped = try await capture("settled")
        c.model.isMotionPaused = false
        try await Task.sleep(for: .milliseconds(650))
        let moving = try await capture("motor-resumed")
        let g = RecordAppearanceGeometry(sceneWidth: width)
        let scale = CGFloat(stopped.pixelsWide) / width
        // Full-window capture includes the 38-pt title and 42-pt explanation above the scene.
        let centre = g.platterCenter(in: .material)
        let crop = CGRect(x: centre.x - g.recordDiameter / 2, y: centre.y + 80 - g.recordDiameter / 2,
                          width: g.recordDiameter, height: g.recordDiameter).applying(CGAffineTransform(scaleX: scale, y: scale))
        let a = NSBitmapImageRep(cgImage: try #require(stopped.cgImage?.cropping(to: crop)))
        let b = NSBitmapImageRep(cgImage: try #require(moving.cgImage?.cropping(to: crop)))
        #expect(VinylRenderingFixture.differingAnnulusFraction(a, b) > 0.01)
    }

    @Test(arguments: [CGSize(width: 900, height: 655), CGSize(width: 850, height: 655),
                      CGSize(width: 820, height: 631), CGSize(width: 760, height: 580)])
    func everyControlFitsIntermediateAndShortWindows(_ size: CGSize) async throws {
        let c = RecordAppearanceWindowController(defaults: defaults())
        c.model.isMotionPaused = true
        c.show(); defer { c.close() }
        let w = try window()
        w.minSize = CGSize(width: 1, height: 1)
        w.setFrame(CGRect(origin: w.frame.origin, size: size), display: true)
        try await Task.sleep(for: .milliseconds(150))
        let ids = RecordAppearanceFamily.allCases.flatMap { RecordAppearanceChoice.choices(in: $0) }.map(\.nameKey) + ["appearance.motion"]
        for id in ids {
            let node = try AppearanceTestAccessibility.element(id, in: w)
            let rect = try #require(node.object.accessibilityFrame?())
            #expect(w.frame.insetBy(dx: -0.5, dy: -0.5).contains(rect), "\(id) must stay in the window at \(size)")
            #expect(rect.height >= 30, "\(id) must retain a comfortable target height")
        }
        if VinylRenderingFixture.canCapture {
            w.orderFrontRegardless()
            _ = try await VinylRenderingFixture.capture(w, to: VinylRenderingFixture.directory
                .appendingPathComponent("appearance-fit-\(Int(size.width))x\(Int(size.height)).png"))
        }
    }

    @Test func occlusionStopsPreviewWork() async throws {
        let c = RecordAppearanceWindowController(defaults: defaults())
        c.show(); defer { c.close() }
        let w = try window()
        w.orderOut(nil)
        try await Task.sleep(for: .milliseconds(150))
        #expect(!c.model.isPreviewVisible)
        c.show()
        #expect(w.isVisible)
    }
}
