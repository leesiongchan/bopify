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
            try? JSONSerialization.data(withJSONObject: results.values, options: [.sortedKeys]).write(to: report, options: .atomic)
            controller.close()
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
            schedule(2.6) { finish() }
        }
        schedule(0.5) { beginWhenKey() }
        schedule(12) { finish() }
        app.run()
    }
}
@MainActor private final class KeyboardResults {
    var window: NSWindow?
    var values: [String: Any] = [:]
}
