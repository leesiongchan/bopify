import AppKit
import SwiftUI
import Observation
import OSLog

@MainActor @Observable private final class FixtureState {
    var presented = false
    var mark: ((String) -> Void)?
}

private struct FixtureView: View {
    let state: FixtureState
    private var binding: Binding<Bool> {
        Binding(get: { state.presented }, set: { value in
            state.mark?("binding-set-\(value)")
            state.presented = value
        })
    }
    var body: some View {
        Button("Fixture popover anchor") { state.presented.toggle() }
            .popover(isPresented: binding, arrowEdge: .bottom) {
                Text("Account-free SwiftUI popover")
                    .padding(20)
                    .onAppear { state.mark?("content-appeared") }
                    .onDisappear { state.mark?("content-disappeared") }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private final class FixturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@main @MainActor struct SwiftUIPopoverTransactionRepro {
    static var result: Int32 = 2
    static func main() {
        let args = CommandLine.arguments
        let modes = ["host-binding", "host-orderout", "panel-binding", "panel-orderout", "panel-binding-orderout", "host-systemclose", "panel-systemclose"]
        guard args.count == 2, modes.contains(args[1]) else {
            FileHandle.standardError.write(Data("usage: SwiftUIPopoverTransactionRepro \(modes.joined(separator: "|"))\n".utf8))
            exit(2)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = Delegate(mode: args[1])
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
        exit(result)
    }

    final class Delegate: NSObject, NSApplicationDelegate {
        let mode: String
        let logger = Logger(subsystem: "bopify.validation", category: "swiftui-popover-transaction")
        let started = Date()
        private let state = FixtureState()
        var window: NSWindow?
        var lifecycle: [String] = []
        weak var observedPopover: NSPopover?
        var observedPopoverID: ObjectIdentifier?
        init(mode: String) { self.mode = mode }
        func mark(_ event: String) {
            lifecycle.append(event)
            logger.notice("fixture \(event, privacy: .public)")
        }
        func applicationDidFinishLaunching(_ notification: Notification) {
            state.mark = { [weak self] event in self?.mark(event) }
            NotificationCenter.default.addObserver(self, selector: #selector(popoverDidShow(_:)), name: NSPopover.didShowNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(popoverDidClose(_:)), name: NSPopover.didCloseNotification, object: nil)
            mark("started")
            let root = FixtureView(state: state)
            let window: NSWindow
            if mode.hasPrefix("panel-") {
                let panel = FixturePanel(contentRect: NSRect(x: 100, y: 100, width: 410, height: 360),
                                         styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
                panel.isFloatingPanel = false
                panel.level = .normal
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                panel.hidesOnDeactivate = false
                panel.isMovable = true
                panel.backgroundColor = .clear
                panel.isOpaque = false
                panel.hasShadow = true
                panel.acceptsMouseMovedEvents = true
                let host = NSHostingView(rootView: root)
                host.sizingOptions = []
                host.frame = NSRect(x: 0, y: 0, width: 410, height: 360)
                host.autoresizingMask = [.width, .height]
                let container = NSView(frame: host.frame)
                container.addSubview(host)
                panel.contentView = container
                window = panel
            } else {
                window = NSWindow(contentViewController: NSHostingController(rootView: root))
                window.styleMask = [.titled, .closable]
                window.setFrame(NSRect(x: 100, y: 100, width: 410, height: 360), display: false)
            }
            window.title = "Account-free SwiftUI popover fixture"
            self.window = window
            NSApplication.shared.activate()
            window.makeKeyAndOrderFront(nil)
            mark("window-shown")
            Task { @MainActor in
                do {
                    try await Task.sleep(for: .milliseconds(700))
                    mark("pre-show-key-\(window.isKeyWindow)-active-\(NSApplication.shared.isActive)")
                    mark("show-requested")
                    state.presented = true
                    try await Task.sleep(for: .milliseconds(1500))
                    mark("close-requested")
                    if mode.hasSuffix("systemclose") { observedPopover?.performClose(nil) }
                    if mode.hasSuffix("binding") || mode == "panel-binding-orderout" {
                        mark("binding-dismiss-requested")
                        state.presented = false
                    }
                    if mode.hasSuffix("orderout") {
                        mark("parent-orderout-requested")
                        window.orderOut(nil)
                    }
                    try await Task.sleep(for: .seconds(2))
                    mark("collection-requested")
                    try await Task.sleep(for: .milliseconds(300))
                    try collect()
                } catch {
                    FileHandle.standardError.write(Data("ERROR: \(error)\n".utf8))
                    SwiftUIPopoverTransactionRepro.result = 2
                }
                NSApplication.shared.terminate(nil)
            }
        }
        @objc func popoverDidShow(_ notification: Notification) {
            guard let popover = notification.object as? NSPopover else { return }
            observedPopover = popover
            observedPopoverID = ObjectIdentifier(popover)
            mark("did-show")
        }
        @objc func popoverDidClose(_ notification: Notification) {
            guard let popover = notification.object as? NSPopover, ObjectIdentifier(popover) == observedPopoverID else { return }
            mark("did-close")
        }
        func collect() throws {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let entries = try store.getEntries(at: store.position(date: started)).compactMap { $0 as? OSLogEntryLog }
            let needles = ["Ignoring request to entangle context after pre-commit", "Entangling fence requested after pre-commit",
                           "cannot add handler", "Invalid attempt to open a new transaction during CA commit"]
            for entry in entries where entry.subsystem == "bopify.validation" || entry.category == "NSCGS" || entry.category == "Popover" || needles.contains(where: { entry.composedMessage.contains($0) }) {
                FileHandle.standardOutput.write(Data("LOG: \(entry.date.ISO8601Format()) \(entry.subsystem)/\(entry.category) \(entry.composedMessage)\n".utf8))
            }
            let required = ["started", "window-shown", "show-requested", "did-show", "close-requested", "did-close", "collection-requested"]
            let showIndex = lifecycle.firstIndex(of: "did-show")
            let closeRequestIndex = lifecycle.firstIndex(of: "close-requested")
            let closeIndex = lifecycle.firstIndex(of: "did-close")
            guard required.allSatisfy({ event in lifecycle.filter { $0 == event }.count == 1 && entries.contains { $0.composedMessage == "fixture \(event)" } }),
                  let showIndex, let closeRequestIndex, let closeIndex,
                  showIndex < closeRequestIndex, closeRequestIndex < closeIndex,
                  observedPopover == nil || observedPopover?.isShown == false else {
                throw NSError(domain: "SwiftUIPopoverTransactionRepro.InvalidLifecycleOrMissingLogMarkers", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "lifecycle=\(lifecycle), binding=\(state.presented), popoverShown=\(observedPopover?.isShown.description ?? "unknown")"])
            }
            let diagnostics = entries.filter { entry in needles.contains { entry.composedMessage.contains($0) } }
            FileHandle.standardOutput.write(Data("RESULT: mode=\(mode) lifecycleValidated=true binding=\(state.presented) parentVisible=\(window?.isVisible.description ?? "unknown") diagnostics=\(diagnostics.count) invalidTransactions=\(diagnostics.filter { $0.composedMessage.contains("Invalid attempt") }.count)\n".utf8))
            SwiftUIPopoverTransactionRepro.result = diagnostics.isEmpty ? 0 : 1
        }
        func applicationWillTerminate(_ notification: Notification) { exit(SwiftUIPopoverTransactionRepro.result) }
    }
}
