import AppKit
import OSLog

@main @MainActor struct StatusItemRepro {
    static var result: Int32 = 0

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(CommandLine.arguments.contains("regular") ? .regular : .accessory)
        let delegate = Delegate()
        app.delegate = delegate
        if CommandLine.arguments.contains("prelaunch") { delegate.install() }
        withExtendedLifetime(delegate) { app.run() }
        exit(result)
    }

    final class Delegate: NSObject, NSApplicationDelegate {
        private var item: NSStatusItem?

        func applicationDidFinishLaunching(_ notification: Notification) {
            if !CommandLine.arguments.contains("prelaunch") { install() }
        }

        func applicationWillTerminate(_ notification: Notification) {
            exit(result)
        }

        func install() {
            let start = Date()
            Logger(subsystem: "bopify.validation", category: "statusitem").notice("minimal status item started")
            let square = CommandLine.arguments.contains("square")
            item = NSStatusBar.system.statusItem(withLength: square ? NSStatusItem.squareLength : NSStatusItem.variableLength)
            item?.button?.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Minimal status item")
            Task { @MainActor in
                do {
                    try await Task.sleep(for: .seconds(3))
                    let store = try OSLogStore(scope: .currentProcessIdentifier)
                    let entries = try store.getEntries(at: store.position(date: start)).compactMap { $0 as? OSLogEntryLog }
                    guard entries.contains(where: { $0.composedMessage == "minimal status item started" }) else {
                        throw NSError(domain: "StatusItemRepro.MissingLogMarker", code: 1)
                    }
                    let failures = entries.filter { $0.composedMessage.contains("already being laid out") }
                    for failure in failures {
                        FileHandle.standardOutput.write(Data("DIAGNOSTIC: \(failure.composedMessage)\n".utf8))
                    }
                    FileHandle.standardOutput.write(Data("RESULT: regular=\(CommandLine.arguments.contains("regular")) square=\(square) recursionCount=\(failures.count)\n".utf8))
                    result = failures.isEmpty ? 0 : 1
                } catch {
                    FileHandle.standardError.write(Data("ERROR: diagnostic collection failed: \(error)\n".utf8))
                    result = 2
                }
                if let item { NSStatusBar.system.removeStatusItem(item) }
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
