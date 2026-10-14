import AppKit
import SwiftUI
import Observation
import ScreenCaptureKit
import BopifyPlayback
import BopifyDomain

@MainActor @Observable private final class MenuState {
    var status: PlaybackConnectionStatus = .ready
    var unavailable = false
    var retries = 0
    var reconnects = 0
    var capsuleSize = CGSize.zero
    var connection: PlaybackConnectionStatusView {
        PlaybackConnectionStatusView(status: status, restorationUnavailable: unavailable,
            onRetry: { self.retries += 1 }, onReconnect: { self.reconnects += 1 })
    }
}

private struct MenuFixtureView: View {
    let state: MenuState
    var body: some View {
        ZStack(alignment: .bottom) {
            Circle().fill(.gray.opacity(0.2)).frame(width: 118, height: 118)
            if state.connection.isVisible {
                CompactPlaybackConnectionMenu(connection: state.connection)
                    .frame(width: 94, height: 24)
                    .background(.ultraThinMaterial, in: Capsule())
                    .background { GeometryReader { geometry in
                        Color.clear.onAppear { state.capsuleSize = geometry.size }
                    } }
                    .padding(.bottom, 12)
            }
        }.frame(width: 142, height: 142)
    }
}

@MainActor private final class FixturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor private final class MenuProbe: NSObject {
    let state = MenuState()
    let output: URL
    let panel = FixturePanel(contentRect: NSRect(x: 200, y: 200, width: 142, height: 142),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    var pendingAction = ""
    var selectionFailure: String?
    var selectionFinished = false
    var rows: [[String: Any]] = []
    var inputVerified = true
    var fullNamesVerified = true

    init(output: URL) { self.output = output; super.init() }
    func attribute(_ object: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        let value = object.perform(selector)?.takeUnretainedValue()
        return (value as? NSAttributedString)?.string ?? value
    }
    func tree(_ object: Any) -> [NSObject] {
        guard let object = object as? NSObject else { return [] }
        return [object] + ((attribute(object, "accessibilityChildren") as? [Any]) ?? []).flatMap(tree)
    }
    func text(_ object: NSObject, _ value: String) -> Bool {
        ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].contains { attribute(object, $0) as? String == value }
    }
    func frame(_ object: NSObject) -> CGRect {
        let selector = NSSelectorFromString("accessibilityFrame")
        precondition(object.responds(to: selector))
        typealias Getter = @convention(c) (AnyObject, Selector) -> CGRect
        return unsafeBitCast(object.method(for: selector), to: Getter.self)(object, selector)
    }
    @discardableResult func press(_ object: NSObject, action: String = "accessibilityPerformPress") -> Bool {
        let selector = NSSelectorFromString(action)
        guard object.responds(to: selector) else { return false }
        typealias Action = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(object.method(for: selector), to: Action.self)(object, selector)
    }
    @objc func selectPending(_ timer: Timer) {
        defer { selectionFinished = true }
        let nodes = NSApp.windows.filter(\.isVisible).compactMap(\.contentView).flatMap(tree)
        if let action = nodes.first(where: { text($0, pendingAction) && attribute($0, "accessibilityRole") as? String == "AXMenuItem" }), press(action) {
            print("SELECTED: \(pendingAction)")
        } else {
            selectionFailure = "Cannot select actual menu action through public accessibility: \(pendingAction)"
            print("Visible fixture accessibility roles: \(nodes.compactMap { attribute($0, "accessibilityRole") as? String })")
            key(53, "\u{1b}")
        }
    }
    func key(_ code: UInt16, _ characters: String) {
        guard NSApp.isActive, CGPreflightPostEventAccess() else { return }
        for down in [true, false] {
            CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)?.postToPid(getpid())
        }
    }
    func render() async { try? await Task.sleep(for: .milliseconds(250)) }
    func capture(_ name: String) async {
        guard #available(macOS 14.4, *) else { print("UNVERIFIED: current-process capture requires macOS 14.4"); return }
        do {
            let content = try await SCShareableContent.currentProcess
            guard let window = content.windows.first(where: { $0.windowID == panel.windowNumber }) else { throw NSError(domain: "MenuProbe.WindowCapture", code: 1) }
            let config = SCStreamConfiguration()
            config.width = 284; config.height = 284; config.ignoreShadowsSingleWindow = true
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
        } catch { print("UNVERIFIED: screenshot \(name): \(error)") }
    }
    func run() async {
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: MenuFixtureView(state: state))
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        print("READY: pid=\(getpid())"); fflush(stdout)
        let deadline = ContinuousClock.now + .seconds(3)
        while !NSApp.isActive && ContinuousClock.now < deadline { await render() }
        await render()
        let initialFrame = panel.frame
        let cases: [(String, PlaybackConnectionStatus, Bool, String?)] = [
            ("connecting", .connecting, false, "Retry now"), ("restoring", .restoring, false, "Retry now"),
            ("reconnecting", .reconnecting, false, "Retry now"), ("offline", .offline, false, "Retry now"),
            ("unavailable", .ready, true, "Retry restoration"),
            ("reauthentication", .needsReauthentication, false, "Reconnect Spotify"),
            ("corrupt", .failed(.credentialCorrupt), false, "Reconnect Spotify"),
            ("credential-retry", .failed(.credentialSaveFailed), false, "Retry saved sign-in"),
            ("permanent", .failed(.premiumRequired), false, nil),
            ("ready", .ready, false, nil), ("stopped", .stopped, false, nil)]
        for (name, status, unavailable, action) in cases {
            state.status = status; state.unavailable = unavailable
            await render()
            let connection = state.connection
            let nodes = tree(panel.contentView!)
            let buttons = nodes.filter { ["AXPopUpButton", "AXMenuButton", "AXButton"].contains(attribute($0, "accessibilityRole") as? String ?? "") }
            if !connection.isVisible {
                precondition(buttons.isEmpty, "Hidden status exposed a menu")
                print("PASS: \(name) hidden")
                continue
            }
            await capture(name)
            guard let button = buttons.first(where: { text($0, connection.messageString) || attribute($0, "accessibilityHelp") as? String == connection.messageString }) else {
                print("FAIL: missing accessible menu \(name), expected=\(connection.messageString)")
                for node in nodes {
                    print("AX: \(attribute(node, "accessibilityRole") ?? "?") title=\(attribute(node, "accessibilityTitle") ?? "") label=\(attribute(node, "accessibilityLabel") ?? "") value=\(attribute(node, "accessibilityValue") ?? "") help=\(attribute(node, "accessibilityHelp") ?? "") type=\(String(describing: type(of: node)))")
                }
                try! JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted]).write(to: output.appendingPathComponent("menu-results.json"))
                exit(2)
            }
            let nameMatches = text(button, connection.messageString)
            fullNamesVerified = fullNamesVerified && nameMatches
            if !nameMatches { print("FAIL: \(name) full explanation is help, but is absent from this local accessibility name") }
            let bounds = frame(button)
            precondition(abs(state.capsuleSize.width - 94) < 0.5 && abs(state.capsuleSize.height - 24) < 0.5, "Capsule layout changed: \(state.capsuleSize)")
            precondition(attribute(button, "accessibilityHelp") as? String == connection.messageString)
            let retries = state.retries, reconnects = state.reconnects
            if let action {
                pendingAction = action
                selectionFailure = nil
                selectionFinished = false
                let timer = Timer(timeInterval: 0.4, target: self, selector: #selector(selectPending(_:)), userInfo: nil, repeats: false)
                RunLoop.main.add(timer, forMode: .common)
                let inputAvailable = NSApp.isActive && CGPreflightPostEventAccess()
                if inputAvailable { _ = press(button, action: "accessibilityPerformShowMenu") || press(button) }
                if !inputAvailable {
                    timer.invalidate()
                    inputVerified = false
                    print("UNVERIFIED: menu input unavailable; active=\(NSApp.isActive)")
                } else {
                    let selectionDeadline = ContinuousClock.now + .seconds(3)
                    while !selectionFinished && ContinuousClock.now < selectionDeadline { await render() }
                    if !selectionFinished { selectionFailure = "Actual menu selection did not complete"; timer.invalidate(); key(53, "\u{1b}") }
                    await render()
                    if let selectionFailure { print("UNVERIFIED: \(selectionFailure)"); inputVerified = false }
                    else {
                        let reconnect = status == .needsReauthentication || status == .failed(.credentialCorrupt)
                        precondition(state.retries == retries + (reconnect ? 0 : 1) && state.reconnects == reconnects + (reconnect ? 1 : 0), "Action dispatch count incorrect")
                    }
                }
            }
            precondition(panel.frame == initialFrame, "Panel frame changed")
            rows.append(["case": name, "message": connection.messageString, "width": state.capsuleSize.width, "height": state.capsuleSize.height, "accessibilityWidth": bounds.width, "accessibilityHeight": bounds.height,
                         "retries": state.retries, "reconnects": state.reconnects, "inputVerified": inputVerified, "fullNameVerified": nameMatches])
            print("PASS: \(name) 94x24 help; fullNameVerified=\(nameMatches) inputVerified=\(inputVerified) counts=\(state.retries)/\(state.reconnects)"); fflush(stdout)
        }
        try! JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("menu-results.json"))
        print("RESULT: geometryValidated=true fullNamesValidated=\(fullNamesVerified) inputVerified=\(inputVerified) keyboardVerified=false")
        exit(fullNamesVerified ? 77 : 2) // Keyboard qualification remains open; a failed name remains a failed gate.
    }
}

@main @MainActor private struct CompactRecoveryMenuProbe {
    static func main() {
        guard CommandLine.arguments.count == 2 else { exit(2) }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let probe = MenuProbe(output: URL(fileURLWithPath: CommandLine.arguments[1]))
        Task { await probe.run() }
        app.run()
    }
}
