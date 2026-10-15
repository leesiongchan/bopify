import AppKit
import SwiftUI
import Observation
import ScreenCaptureKit
import BopifyPlayback
import BopifyDomain

@MainActor @Observable private final class MenuState {
    var status: PlaybackConnectionStatus = .ready
    var unavailable = false
    var capsuleSize = CGSize.zero
    var connection: PlaybackConnectionStatusView {
        PlaybackConnectionStatusView(status: status, restorationUnavailable: unavailable,
            onRetry: {}, onReconnect: {})
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
    var rows: [[String: Any]] = []
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
        for (name, status, unavailable, _) in cases {
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
            precondition(panel.frame == initialFrame, "Panel frame changed")
            rows.append(["case": name, "message": connection.messageString, "width": state.capsuleSize.width, "height": state.capsuleSize.height, "accessibilityWidth": bounds.width, "accessibilityHeight": bounds.height,
                         "fullNameVerified": nameMatches])
            print("PASS: \(name) 94x24 help; fullNameVerified=\(nameMatches)"); fflush(stdout)
        }
        try! JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("menu-results.json"))
        print("RESULT: geometryValidated=true fullNamesValidated=\(fullNamesVerified); input qualification is in RecoveryMenuUITests")
        exit(fullNamesVerified ? 0 : 2)
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
