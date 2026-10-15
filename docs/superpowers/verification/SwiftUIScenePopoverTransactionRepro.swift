import AppKit
import SwiftUI
import Observation
import OSLog

@MainActor @Observable private final class SceneFixture: NSObject {
    let mode: String
    var presented = false
    private let started = Date()
    private let logger = Logger(subsystem: "bopify.validation", category: "swiftui-popover-transaction")
    private var events: [String] = []
    private weak var popover: NSPopover?
    private var popoverID: ObjectIdentifier?
    private var running = false
    private var clickMonitor: Any?
    private let clickTag = Int64.random(in: 1...Int64.max)

    init(mode: String) { self.mode = mode; super.init() }

    func mark(_ event: String) {
        events.append(event)
        logger.notice("fixture \(event, privacy: .public)")
    }

    func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate() {
            guard ContinuousClock.now < deadline else {
                throw NSError(domain: "SceneFixture.LifecycleTimeout", code: 2)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func run() async {
        guard !running else { return }
        running = true
        mark("started")
        NotificationCenter.default.addObserver(self, selector: #selector(didShow(_:)), name: NSPopover.didShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(didClose(_:)), name: NSPopover.didCloseNotification, object: nil)
        var result: Int32 = 2
        do {
            try await wait { NSApp.windows.contains { $0.title == "SwiftUI scene popover fixture" && $0.isVisible } }
            NSApp.activate()
            mark("window-shown")
            print("READY: pid=\(getpid())"); fflush(stdout)
            if mode == "outside", let window = NSApp.windows.first(where: { $0.title == "SwiftUI scene popover fixture" }) {
                let targetWindow = window.windowNumber
                let tag = clickTag
                clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                    let isTarget = event.windowNumber == targetWindow
                        && abs(event.locationInWindow.x - 24) < 2 && abs(event.locationInWindow.y - 24) < 2
                        && event.cgEvent?.getIntegerValueField(.eventSourceUserData) == tag
                    if isTarget { MainActor.assumeIsolated { self?.mark("outside-click-delivered") } }
                    return event
                }
            }
            if mode == "control" {
                mark("control-observed")
            } else {
                mark("show-requested")
                presented = true
                try await wait { events.contains("did-show") && events.contains("content-appeared") }
                try await Task.sleep(for: .milliseconds(300))
                mark("close-requested")
                switch mode {
                case "binding":
                    mark("binding-dismiss-requested")
                    presented = false
                case "outside":
                    guard CGPreflightPostEventAccess() else {
                        print("UNAVAILABLE: event posting not authorized; no permission was requested")
                        _ = try? collect()
                        exit(77)
                    }
                    guard let window = NSApp.windows.first(where: { $0.title == "SwiftUI scene popover fixture" }),
                          let screen = NSScreen.screens.first else { throw NSError(domain: "SceneFixture.MissingWindow", code: 2) }
                    guard NSApp.isActive, window.isKeyWindow else {
                        print("UNAVAILABLE: fixture was not granted foreground/key-window activation; outside-click delivery cannot be qualified")
                        _ = try? collect()
                        exit(77)
                    }
                    // Target only blank content in this process; never send input to the user's app.
                    let point = CGPoint(x: window.frame.minX + 24, y: screen.frame.maxY - window.frame.minY - 24)
                    mark("outside-click-posted")
                    for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else {
                            throw NSError(domain: "SceneFixture.MissingEvent", code: 2)
                        }
                        event.setIntegerValueField(.eventSourceUserData, value: clickTag)
                        event.postToPid(getpid())
                    }
                default: break // missing-close deliberately exercises the invalid-evidence path.
                }
                if mode != "missing-close" {
                    try await wait { events.contains("did-close") && events.contains("content-disappeared") }
                }
            }
            mark("collection-requested")
            try await Task.sleep(for: .seconds(2))
            result = try collect()
        } catch {
            print("INVALID: \(error) events=\(events)")
            _ = try? collect()
        }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        NotificationCenter.default.removeObserver(self)
        fflush(stdout)
        exit(result)
    }

    @objc private func didShow(_ notification: Notification) {
        guard let candidate = notification.object as? NSPopover else { return }
        popover = candidate
        popoverID = ObjectIdentifier(candidate)
        mark("did-show")
    }

    @objc private func didClose(_ notification: Notification) {
        guard let candidate = notification.object as? NSPopover, ObjectIdentifier(candidate) == popoverID else { return }
        mark("did-close")
    }

    func collect() throws -> Int32 {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let entries = try store.getEntries(at: store.position(date: started)).compactMap { $0 as? OSLogEntryLog }
        for entry in entries {
            print("LOG: \(entry.date.ISO8601Format()) \(entry.subsystem)/\(entry.category) \(entry.composedMessage)")
        }
        var ordered = mode == "control"
            ? ["started", "window-shown", "control-observed", "collection-requested"]
            : ["started", "window-shown", "show-requested", "did-show", "close-requested"]
        if mode == "binding" { ordered += ["binding-dismiss-requested"] }
        if mode == "outside" { ordered += ["outside-click-posted", "outside-click-delivered"] }
        if mode != "control" { ordered += ["did-close", "collection-requested"] }
        let required = mode == "control" ? ordered : ordered + ["content-appeared", "content-disappeared"]
        let logged = entries.filter { $0.subsystem == "bopify.validation" && $0.composedMessage.hasPrefix("fixture ") }
            .map { String($0.composedMessage.dropFirst("fixture ".count)) }
        func validates(_ observed: [String]) -> Bool {
            guard required.allSatisfy({ event in observed.filter { $0 == event }.count == 1 }) else { return false }
            if mode == "control" { return observed == ordered }
            let positions = ordered.compactMap { observed.firstIndex(of: $0) }
            guard positions == positions.sorted(),
                  let show = observed.firstIndex(of: "show-requested"), let appear = observed.firstIndex(of: "content-appeared"),
                  let request = observed.firstIndex(of: "close-requested"), let disappear = observed.firstIndex(of: "content-disappeared"),
                  let collect = observed.firstIndex(of: "collection-requested") else { return false }
            return show < appear && appear < request && request < disappear && disappear < collect
        }
        let valid = validates(events) && validates(logged) && !presented && popover?.isShown != true
        let needles = ["Ignoring request to entangle context after pre-commit", "Entangling fence requested after pre-commit",
                       "cannot add handler", "Invalid attempt to open a new transaction during CA commit"]
        let diagnostics = entries.filter { entry in needles.contains { entry.composedMessage.contains($0) } }
        let invalidTransactions = diagnostics.filter { $0.composedMessage.contains("Invalid attempt") }.count
        print("RESULT: mode=\(mode) lifecycleValidated=\(valid) diagnostics=\(diagnostics.count) invalidTransactions=\(invalidTransactions)")
        return valid ? (diagnostics.isEmpty ? 0 : 1) : 2
    }
}

@main @MainActor private struct SwiftUIScenePopoverTransactionRepro: App {
    @State private var fixture: SceneFixture

    init() {
        let args = CommandLine.arguments
        let mode = args.count == 2 ? String(args[1].drop(while: { $0 == "-" })) : ""
        guard ["binding", "outside", "control", "missing-close"].contains(mode) else {
            print("usage: SwiftUIScenePopoverTransactionRepro --binding|--outside|--control|--missing-close")
            exit(2)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(12))
            print("INVALID: no completed lifecycle; visible windows=\(NSApp.windows.map { ($0.title, $0.isVisible) })"); fflush(stdout)
            exit(2)
        }
        _fixture = State(initialValue: SceneFixture(mode: mode))
    }

    var body: some Scene {
        Window("SwiftUI scene popover fixture", id: "fixture") {
            Button("Fixture popover anchor") { fixture.presented.toggle() }
                .popover(isPresented: Binding(get: { fixture.presented }, set: { value in
                    fixture.mark("binding-set-\(value)")
                    fixture.presented = value
                }), arrowEdge: .bottom) {
                    Text("Account-free SwiftUI scene popover")
                        .padding(20)
                        .onAppear { fixture.mark("content-appeared") }
                        .onDisappear { fixture.mark("content-disappeared") }
                }
                .frame(width: 410, height: 360)
                .task { await fixture.run() }
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}
