import AppKit

/// A real application host verifies native focus/Tab traversal, which the background XCTest agent cannot activate.
@main struct VinylKeyboardHost {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let suite = "dev.bopify.appearance-keyboard.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let controller = RecordAppearanceWindowController(defaults: defaults)
        let report = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("keyboard-results.json")
        let results = KeyboardResults()
        var pointerController: RecordAppearanceWindowController?
        controller.show()
        func schedule(_ delay: Double, _ action: @escaping @MainActor () -> Void) {
            Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in MainActor.assumeIsolated { action() } }
        }
        func send(_ code: UInt16, _ text: String = "", modifiers: NSEvent.ModifierFlags = []) {
            guard let window = results.window else { return }
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code) {
                    app.postEvent(event, atStart: false)
                }
            }
        }
        func finish() {
            if results.values.isEmpty {
                let w = results.window
                results.values["activationDiagnostic"] = [
                    "active": app.isActive, "hidden": app.isHidden,
                    "policy": app.activationPolicy().rawValue,
                    "finishedLaunching": NSRunningApplication.current.isFinishedLaunching,
                    "onActiveSpace": w?.isOnActiveSpace ?? false,
                    "visible": w?.isVisible ?? false, "key": w?.isKeyWindow ?? false,
                    "matchingInstances": NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier!).count
                ] as [String: Any]
            }
            try? JSONSerialization.data(withJSONObject: results.values, options: [.sortedKeys]).write(to: report, options: .atomic)
            controller.close()
            pointerController?.close()
            defaults.removePersistentDomain(forName: suite)
            app.terminate(nil)
        }
        func beginWhenKey() {
            results.window = NSApp.windows.first { $0.identifier?.rawValue == "record-appearance" }
            guard app.isActive, results.window?.isKeyWindow == true else {
                app.activate(ignoringOtherApps: true); results.window?.makeKeyAndOrderFront(nil)
                schedule(0.05) { beginWhenKey() }; return
            }
            results.values["windowWasKey"] = true
            schedule(0.1) { send(124, "\u{f703}") }
            schedule(0.2) { send(49, " ") }
            schedule(0.3) { send(125, "\u{f701}") }
            schedule(0.4) { send(119, "\u{f72b}") }
            schedule(0.5) { send(36, "\r") }
            schedule(0.6) {
                results.values["material"] = defaults.string(forKey: RecordDesign.preferenceKey) ?? "none"
                results.values["pattern"] = defaults.string(forKey: VinylDesign.preferenceKey) ?? "none"
                send(115, "\u{f729}")
            }
            schedule(0.7) { send(126, "\u{f700}") }
            schedule(0.8) { send(48, "\t") }
            schedule(0.9) {
                results.values["tabForward"] = controller.model.focused == .choice(.material(.glass))
                send(48, "\t", modifiers: .shift)
            }
            schedule(1.0) { results.values["tabBackward"] = controller.model.focused == .choice(.material(.classic)) }
            for index in 0..<9 { schedule(1.1 + Double(index) * 0.08) { send(48, "\t") } }
            schedule(1.9) {
                results.values["motionFocused"] = controller.model.focused == .motion
                send(49, " ")
            }
            schedule(2.1) {
                results.values["motionPaused"] = controller.model.isMotionPaused
                results.values["motionKeptChoices"] = defaults.string(forKey: RecordDesign.preferenceKey) == "glass" && defaults.string(forKey: VinylDesign.preferenceKey) == "carnival"
                send(53, "\u{1b}")
            }
            schedule(2.3) {
                results.values["escapeCloses"] = results.window?.isVisible == false
                controller.show()
                results.values["reusesWindow"] = NSApp.windows.first { $0.identifier?.rawValue == "record-appearance" && $0.isVisible } === results.window
            }
            schedule(2.6) {
                controller.close()
                defaults.set("glass", forKey: RecordDesign.preferenceKey)
                defaults.set("bloom", forKey: VinylDesign.preferenceKey)
                let pointer = RecordAppearanceWindowController(defaults: defaults)
                pointer.model.isMotionPaused = true
                pointer.show()
                pointerController = pointer
                results.window = NSApp.windows.first { $0.identifier?.rawValue == "record-appearance" && $0.isVisible }
                if let w = results.window {
                    w.setFrame(CGRect(origin: w.frame.origin, size: CGSize(width: 760, height: 631)), display: true)
                }
            }
            func click(_ x: CGFloat, _ top: CGFloat) {
                guard let w = results.window, let host = w.contentView else { return }
                let point = host.convert(CGPoint(x: x, y: host.isFlipped ? top : host.bounds.height - top), to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil,
                        eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) {
                        app.postEvent(event, atStart: false)
                    }
                }
            }
            let g = RecordAppearanceGeometry(sceneWidth: 760)
            func beginPointerWhenKey() {
                guard let w = results.window, app.isActive, w.isKeyWindow else {
                    app.activate(ignoringOtherApps: true)
                    results.window?.makeKeyAndOrderFront(nil)
                    schedule(0.05) { beginPointerWhenKey() }
                    return
                }
                results.values["pointerWindowKey"] = true
                schedule(0.2) {
                    results.values["previewVisible"] = pointerController?.model.isPreviewVisible ?? false
                    click(20, 80 + g.home(for: .material(.classic)).y - g.recordDiameter * 0.25)
                }
                schedule(0.4) {
                    results.values["pointerMaterial"] = pointerController?.model.selectedMaterial == .classic
                    results.beforeBlankMaterial = pointerController?.model.selectedMaterial
                    results.beforeBlankPattern = pointerController?.model.selectedPattern
                    click(380, 80 + g.sceneHeight / 2)
                }
                schedule(0.6) {
                    results.values["blankKeepsChoices"] = pointerController?.model.selectedMaterial == results.beforeBlankMaterial && pointerController?.model.selectedPattern == results.beforeBlankPattern
                    click(740, 80 + g.home(for: .pattern(.original)).y - g.recordDiameter * 0.42)
                }
                schedule(0.8) { results.values["pointerPattern"] = pointerController?.model.selectedPattern == .original }
                schedule(1.0) { finish() }
            }
            schedule(2.8) { beginPointerWhenKey() }
        }
        schedule(0.5) { beginWhenKey() }
        schedule(12) { finish() }
        app.run()
    }
}
@MainActor private final class KeyboardResults {
    var window: NSWindow?
    var beforeBlankMaterial: RecordDesign?
    var beforeBlankPattern: VinylDesign?
    var values: [String: Any] = [:]
}
