import SwiftUI
import ScreenCaptureKit
import BopifyPlayback

private struct WindowScene: View {
    let controller: PlayerWindowController
    var body: some View {
        let layout = controller.layout
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 28).fill(.gray.opacity(0.9))
                .overlay(PlayerBackgroundDragRegion().clipShape(RoundedRectangle(cornerRadius: 28)))
                .frame(width: layout.sleeveFrame.width, height: layout.sleeveFrame.height)
                .offset(x: layout.sleeveFrame.minX, y: layout.sleeveFrame.minY)
            Circle().fill(.black)
                .overlay(Circle().stroke(.white, lineWidth: 1))
                .overlay(PlayerBackgroundDragRegion().frame(width: 64, height: 64))
                .frame(width: layout.recordDiameter, height: layout.recordDiameter)
                .position(layout.recordCenter)
        }
        .frame(width: layout.contentSize.width, height: layout.contentSize.height, alignment: .topLeading)
        .offset(x: controller.contentOffset.x, y: controller.contentOffset.y)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

@main struct MonolithWindowProbe {
    @MainActor static var target: NSWindow?
    @MainActor static var targetClicks = 0
    static var output: URL { URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true) }
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        if CommandLine.arguments.contains("--background") {
            let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 1000, height: 650),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.backgroundColor = .systemTeal
            window.contentView = BackgroundTarget()
            target = window
            window.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)
            writeTargetState()
        } else {
            Task { @MainActor in
                do { try await run(); print("MONOLITH WINDOW PASS"); app.terminate(nil) }
                catch { print("MONOLITH WINDOW FAIL: \(error)"); exit(1) }
            }
        }
        app.run()
    }

    @MainActor private final class BackgroundTarget: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            targetClicks += 1
            writeTargetState()
        }
    }
    @MainActor static func writeTargetState() {
        let state = "\(target?.windowNumber ?? -1),\(targetClicks)"
        try! state.write(to: output.appendingPathComponent("background.txt"), atomically: true, encoding: .utf8)
    }
    @MainActor static func check(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: message, code: 1) }
        print("PASS: \(message)")
    }
    @MainActor static func settle(_ milliseconds: Int = 850) async throws {
        try await Task.sleep(for: .milliseconds(milliseconds))
    }
    @MainActor static func run() async throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "com.leesiongchan.monolith-probe.\(UUID())")!
        defaults.set("{{200, 300}, {410, 560}}", forKey: "player.frame")
        try check(PlayerWindowController.restoredAnchor(defaults: defaults) == CGPoint(x: 405, y: 580), "legacy midpoint migration")
        defaults.set("{nan, inf}", forKey: "player.recordCenter")
        try check(PlayerWindowController.restoredAnchor(defaults: defaults) == CGPoint(x: 405, y: 580), "invalid saved center falls back to legacy")
        defaults.set("{420, 440}", forKey: "player.recordCenter")
        let controller = PlayerWindowController(defaults: defaults)
        let presentation = PlayerPresentation()
        let panel = StatusPanel(content: WindowScene(controller: controller))
        controller.attach(to: panel)
        try check(!panel.hasShadow, "listening window omits the native outline-producing shadow")
        controller.apply(mode: .compact, reduceMotion: true)
        let background = Process()
        background.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        background.arguments = [output.path, "--background"]
        try background.run()
        defer { background.terminate(); panel.orderOut(nil) }
        try await settle()
        panel.orderFrontRegardless()
        presentation.sendAttention(.visibility(true))
        panel.onPointerChanged = { active in
            presentation.sendAttention(.pointer(active))
            if active { controller.apply(mode: .expanded, reduceMotion: false) }
        }
        panel.onKeyChanged = { presentation.sendAttention(.keyboardFocus($0)) }
        panel.onWindowDragChanged = { controller.setDragging($0); presentation.sendAttention(.interaction(.windowDrag, $0)) }
        func spindle() -> CGPoint {
            CGPoint(x: panel.frame.minX + controller.contentOffset.x + controller.layout.recordCenter.x,
                    y: panel.frame.maxY - controller.contentOffset.y - controller.layout.recordCenter.y)
        }
        let original = spindle()
        for mode in [PlayerMode.expanded, .queue, .compact] {
            controller.apply(mode: mode, reduceMotion: false)
            try check(hypot(spindle().x - original.x, spindle().y - original.y) < 0.5, "spindle stable allocating \(mode)")
            try await settle()
            try check(!controller.isTransitioning, "\(mode) animation completes")
            try check(hypot(spindle().x - original.x, spindle().y - original.y) < 0.5, "spindle stable settling \(mode)")
            try await capture(panel, name: "window-\(mode.rawValue)")
        }
        for index in 0..<20 {
            controller.apply(mode: index.isMultiple(of: 2) ? .expanded : .compact, reduceMotion: false)
            let stale = controller.transitionID
            controller.apply(mode: .queue, reduceMotion: false)
            let envelope = panel.frame
            controller.finishTransition(stale)
            try check(panel.frame == envelope, "stale completion \(index) cannot shrink window")
            try await settle(20)
        }
        controller.apply(mode: .compact, reduceMotion: false)
        try await settle()
        try check(panel.frame.size == CGSize(width: 142, height: 142), "interruptions settle tightly")
        try check(!panel.isKeyWindow, "reveals do not take keyboard focus")
        let state = try String(contentsOf: output.appendingPathComponent("background.txt"), encoding: .utf8).split(separator: ",")
        let backgroundNumber = Int(state[0])!
        let corner = CGPoint(x: panel.frame.minX + 2, y: panel.frame.minY + 2)
        try check(NSWindow.windowNumber(at: corner, belowWindowWithWindowNumber: 0) == backgroundNumber,
                  "transparent resting corner belongs to background process")
        let outside = CGPoint(x: original.x + 210, y: original.y)
        try check(NSWindow.windowNumber(at: outside, belowWindowWithWindowNumber: 0) == backgroundNumber,
                  "collapsed sleeve area belongs to background process")
        try check(CGPreflightPostEventAccess(), "permission to deliver controlled WindowServer mouse events")
        mouse(.leftMouseDown, at: corner)
        mouse(.leftMouseUp, at: corner)
        try await settle(150)
        let clicked = try String(contentsOf: output.appendingPathComponent("background.txt"), encoding: .utf8).split(separator: ",")
        try check(Int(clicked[1])! > Int(state[1])!, "background process receives actual click through transparent corner")
        // Clicking the background raises it; expose the player without activating it.
        panel.orderFrontRegardless()
        try await settle(150)
        mouse(.mouseMoved, at: original)
        try await settle()
        try check(presentation.mode == .expanded && !panel.isKeyWindow, "actual hover reveals without focus theft")
        let grab = CGPoint(x: panel.frame.maxX - 30, y: panel.frame.minY + 28)
        mouse(.leftMouseDown, at: grab)
        mouse(.leftMouseUp, at: grab)
        try await settle(150)
        try check(panel.isKeyWindow, "background click acquires focus")
        try check(spindle() == original, "background click does not move record")
        mouse(.leftMouseDown, at: grab)
        mouse(.leftMouseDragged, at: CGPoint(x: grab.x + 3, y: grab.y))
        try await settle(80)
        try check(spindle() == original, "drag slop does not move record")
        mouse(.leftMouseDragged, at: CGPoint(x: grab.x + 30, y: grab.y + 20))
        try await settle(80)
        mouse(.leftMouseUp, at: CGPoint(x: grab.x + 30, y: grab.y + 20))
        try await settle(150)
        try check(abs(spindle().x - original.x - 30) < 1 && abs(spindle().y - original.y - 20) < 1, "background drag translates the record")
        try check(!controller.isDragging, "drag releases attention hold")
        try check(PlayerWindowController.restoredAnchor(defaults: defaults) == spindle(), "dragged anchor persists")
        panel.onPointerChanged = nil
        controller.apply(mode: .queue, reduceMotion: false)
        try await settle()
        try check(panel.frame.height > 264, "queue is extended before drag interruption")
        controller.apply(mode: .compact, reduceMotion: false)
        try await settle(60)
        controller.setDragging(true)
        panel.setFrameOrigin(CGPoint(x: panel.frame.minX + 10, y: panel.frame.minY))
        controller.setDragging(false)
        try await settle()
        try check(panel.frame.size == controller.layout.contentSize, "drag during collapse settles to tight bounds")
        let boundary = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let bottomDefaults = UserDefaults(suiteName: "monolith.bottom.\(UUID())")!
        bottomDefaults.set("{300, 132}", forKey: "player.recordCenter")
        let bottomController = PlayerWindowController(defaults: bottomDefaults)
        let bottomPanel = StatusPanel(content: WindowScene(controller: bottomController))
        bottomController.attach(to: bottomPanel)
        bottomController.apply(mode: .expanded, reduceMotion: true, visibleFrame: boundary)
        let bottomFrame = bottomPanel.frame
        bottomController.apply(mode: .queue, reduceMotion: true, visibleFrame: boundary)
        try check(bottomPanel.frame == bottomFrame, "bottom-edge lower section switches without moving the window")
        try check(bottomController.layout.lowerFrame.height >= 80, "bottom-edge queue retains a usable viewport")
        try check(boundary.contains(bottomPanel.frame), "bottom-edge queue stays inside screen")
        bottomController.apply(mode: .compact, reduceMotion: true, visibleFrame: boundary)
        try check(bottomPanel.frame.size == CGSize(width: 142, height: 142), "bottom-edge queue collapses tightly")
    }
    @MainActor static func mouse(_ type: CGEventType, at point: CGPoint) {
        let height = NSScreen.screens.first!.frame.maxY
        let event = CGEvent(mouseEventSource: nil, mouseType: type,
                            mouseCursorPosition: CGPoint(x: point.x, y: height - point.y), mouseButton: .left)!
        event.post(tap: .cghidEventTap)
    }
    @MainActor static func capture(_ panel: StatusPanel, name: String) async throws {
        let content = try await SCShareableContent.currentProcess
        guard let window = content.windows.first(where: { $0.windowID == panel.windowNumber }) else {
            throw NSError(domain: "Missing capture window", code: 1)
        }
        let config = SCStreamConfiguration()
        config.width = Int(panel.frame.width * 2)
        config.height = Int(panel.frame.height * 2)
        config.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
            .write(to: output.appendingPathComponent(name + ".png"))
    }
}
