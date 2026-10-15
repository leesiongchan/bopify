import AppKit
import SwiftUI
import OSLog

@MainActor private final class Observation {
    let started = Date()
    let control: Bool
    let output: URL
    let logger = Logger(subsystem: "bopify.validation", category: "swiftui-statusitem")

    init() {
        let args = CommandLine.arguments
        guard args.count == 3, ["item", "noitem"].contains(args[1]) else { exit(2) }
        control = args[1] == "noitem"
        output = URL(fileURLWithPath: args[2])
        logger.notice("swiftui status item started")
    }

    func collect() async {
        do {
            try await Task.sleep(for: .seconds(3))
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let entries = try store.getEntries(at: store.position(date: started)).compactMap { $0 as? OSLogEntryLog }
            guard entries.contains(where: { $0.composedMessage == "swiftui status item started" }) else {
                throw NSError(domain: "SwiftUIStatusItem.MissingMarker", code: 1)
            }
            let windows = NSApp.windows.map { NSStringFromClass(type(of: $0)) }
            // Observation only: SwiftUI owns creation and presentation of every scene and window.
            let statusWindows = windows.filter { $0.contains("StatusBarWindow") }.count
            guard control ? statusWindows == 0 : statusWindows > 0 else {
                throw NSError(domain: "SwiftUIStatusItem.MissingScene", code: 2)
            }
            let failures = entries.filter { $0.composedMessage.contains("already being laid out") }
            let records = entries.map { ["time": $0.date.timeIntervalSince(started), "subsystem": $0.subsystem,
                "category": $0.category, "message": $0.composedMessage] as [String: Any] }
            let data = try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: output, options: .atomic)
            for failure in failures { print("DIAGNOSTIC: \(failure.composedMessage)") }
            print("RESULT: control=\(control) statusWindows=\(statusWindows) recursionCount=\(failures.count) records=\(entries.count)")
            fflush(stdout)
            exit(failures.isEmpty ? 0 : 1)
        } catch {
            print("INVALID: \(error)"); fflush(stdout); exit(2)
        }
    }
}

@main @MainActor private struct SwiftUIStatusItemRepro: App {
    private let observation: Observation
    init() {
        let observation = Observation()
        self.observation = observation
        Task { await observation.collect() }
    }
    var body: some Scene {
        #if NO_ITEM
        Settings { EmptyView() }
        #else
        MenuBarExtra("Minimal status item", systemImage: "music.note") {
            Text("Account-free control")
        }
        #endif
    }
}
