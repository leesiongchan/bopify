import AppKit

/// A real application host is necessary: XCTest's background agent cannot become active.
@main struct VinylKeyboardHost {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let suite = "dev.bopify.vinyl-keyboard.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let controller = VinylDesignWindowController(defaults: defaults)
        let report = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("keyboard-results.json")
        let results = KeyboardResults()
        controller.show()

        func schedule(_ delay: Double, _ action: @escaping @MainActor () -> Void) {
            Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
                MainActor.assumeIsolated { action() }
            }
        }
        func send(_ text: String, code: UInt16) {
            guard let window = results.window else { return }
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let event = NSEvent.keyEvent(with: type, location: .zero,
                    modifierFlags: (123...126).contains(code) ? [.function, .numericPad] : [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: text,
                    charactersIgnoringModifiers: text, isARepeat: false, keyCode: code) {
                    app.postEvent(event, atStart: false)
                }
            }
        }
        func finish() {
            let payload: [String: Any] = ["keyboardStyle": results.style ?? "none", "escapeCloses": results.closed,
                "returnStyle": results.returnStyle ?? "none", "reusesWindow": results.reused, "windowWasKey": results.wasKey]
            try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]).write(to: report, options: .atomic)
            controller.close()
            defaults.removePersistentDomain(forName: suite)
            app.terminate(nil)
        }

        schedule(0.5) {
            results.window = NSApp.windows.first { $0.identifier?.rawValue == "vinyl-design" }
            app.activate()
            results.window?.makeKeyAndOrderFront(nil)
            results.wasKey = results.window?.isKeyWindow == true
        }
        schedule(0.7) { send("\u{f701}", code: 125) }
        schedule(0.9) { send("\u{f701}", code: 125) }
        schedule(1.1) { send(" ", code: 49) }
        schedule(1.3) {
            results.style = defaults.string(forKey: VinylDesign.preferenceKey)
            send("\u{1b}", code: 53)
        }
        schedule(1.5) {
            results.closed = results.window?.isVisible == false
            controller.show()
            results.reused = NSApp.windows.first { $0.identifier?.rawValue == "vinyl-design" && $0.isVisible } === results.window
        }
        schedule(1.7) { send("\u{f703}", code: 124) }
        schedule(1.9) { send("\r", code: 36) }
        schedule(2.1) {
            results.returnStyle = defaults.string(forKey: VinylDesign.preferenceKey)
            finish()
        }
        schedule(10) { finish() }
        app.run()
    }
}

@MainActor private final class KeyboardResults {
    var window: NSWindow?
    var style: String?
    var returnStyle: String?
    var wasKey = false
    var closed = false
    var reused = false
}
