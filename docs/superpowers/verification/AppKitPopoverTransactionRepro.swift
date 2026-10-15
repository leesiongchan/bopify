import AppKit
import OSLog

@main @MainActor struct PopoverTransactionRepro {
    static var result: Int32 = 2
    static func main() {
        let args = CommandLine.arguments
        guard args.count == 2, ["animated", "nonanimated", "control"].contains(args[1]) else {
            FileHandle.standardError.write(Data("usage: PopoverTransactionRepro animated|nonanimated|control\n".utf8))
            exit(2)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = Delegate(mode: args[1])
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
        exit(result)
    }

    final class Delegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
        let mode: String
        let logger = Logger(subsystem: "bopify.validation", category: "popover-transaction")
        let started = Date()
        var window: NSWindow?
        var popover: NSPopover?
        var lifecycle: [String] = []
        init(mode: String) { self.mode = mode }

        func mark(_ event: String) {
            lifecycle.append(event)
            logger.notice("fixture \(event, privacy: .public)")
        }
        func applicationDidFinishLaunching(_ notification: Notification) {
            mark("started")
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 200),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Account-free popover transaction fixture"
            let button = NSButton(title: "Anchor", target: nil, action: nil)
            button.frame = NSRect(x: 100, y: 80, width: 100, height: 32)
            window.contentView?.addSubview(button)
            self.window = window
            window.orderFrontRegardless()
            mark("window-shown")
            Task { @MainActor in
                do {
                    try await Task.sleep(for: .milliseconds(500))
                    if mode != "control" {
                        let popover = NSPopover()
                        popover.animates = mode == "animated"
                        popover.behavior = .applicationDefined
                        let controller = NSViewController()
                        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 120))
                        let label = NSTextField(labelWithString: "Plain AppKit content")
                        label.frame = NSRect(x: 15, y: 50, width: 140, height: 22)
                        controller.view.addSubview(label)
                        popover.contentViewController = controller
                        popover.contentSize = NSSize(width: 160, height: 120)
                        popover.delegate = self
                        self.popover = popover
                        mark("show-requested")
                        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
                        try await Task.sleep(for: .milliseconds(1200))
                        mark("close-requested")
                        popover.close()
                    } else {
                        mark("control-observed")
                        try await Task.sleep(for: .milliseconds(1200))
                    }
                    try await Task.sleep(for: .seconds(2))
                    mark("collection-requested")
                    try await Task.sleep(for: .milliseconds(300))
                    try collect()
                } catch {
                    FileHandle.standardError.write(Data("ERROR: \(error)\n".utf8))
                    PopoverTransactionRepro.result = 2
                }
                NSApplication.shared.terminate(nil)
            }
        }
        func popoverDidShow(_ notification: Notification) { mark("did-show") }
        func popoverDidClose(_ notification: Notification) { mark("did-close") }

        func collect() throws {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let entries = try store.getEntries(at: store.position(date: started)).compactMap { $0 as? OSLogEntryLog }
            let expected = mode == "control"
                ? ["started", "window-shown", "control-observed", "collection-requested"]
                : ["started", "window-shown", "show-requested", "did-show", "close-requested", "did-close", "collection-requested"]
            guard lifecycle == expected,
                  expected.allSatisfy({ event in entries.contains { $0.composedMessage == "fixture \(event)" } }) else {
                throw NSError(domain: "PopoverTransactionRepro.InvalidLifecycleOrMissingLogMarkers", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "observed lifecycle=\(lifecycle)"])
            }
            let needles = ["Ignoring request to entangle context after pre-commit", "Entangling fence requested after pre-commit",
                           "cannot add handler", "Invalid attempt to open a new transaction during CA commit"]
            let diagnostics = entries.filter { entry in needles.contains { entry.composedMessage.contains($0) } }
            for entry in entries where entry.subsystem == "bopify.validation" || entry.category == "NSCGS" || needles.contains(where: { entry.composedMessage.contains($0) }) {
                FileHandle.standardOutput.write(Data("LOG: \(entry.date.ISO8601Format()) \(entry.subsystem)/\(entry.category) \(entry.composedMessage)\n".utf8))
            }
            FileHandle.standardOutput.write(Data("RESULT: mode=\(mode) lifecycleValidated=true diagnostics=\(diagnostics.count) invalidTransactions=\(diagnostics.filter { $0.composedMessage.contains("Invalid attempt") }.count)\n".utf8))
            PopoverTransactionRepro.result = diagnostics.isEmpty ? 0 : 1
        }
        func applicationWillTerminate(_ notification: Notification) { exit(PopoverTransactionRepro.result) }
    }
}
