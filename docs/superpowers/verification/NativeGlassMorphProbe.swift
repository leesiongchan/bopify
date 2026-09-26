import SwiftUI
import ScreenCaptureKit
import BopifyDomain
import BopifyPlayback
// Compile using run-glass-morph-probe.py, then launch the generated app executable.
@main struct NativeGlassMorphProbe {
    static var outputDirectory: URL {
        URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/private/tmp/bopify-glass-morph-captures", isDirectory: true)
    }
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        Task { @MainActor in
            do {
                try await runVisuals()
                try await runGestures()
                print("NATIVE PROBE PASS")
                app.terminate(nil)
            } catch {
                print("NATIVE PROBE ERROR: \(error)")
                exit(1)
            }
        }
        app.run()
    }
    @MainActor static func runVisuals() async throws {
        let fixture = PlayerMotionFixture()
        let panel = StatusPanel(content: PlayerMotionScene(fixture: fixture))
        panel.setFrame(NSRect(x: 100, y: 100, width: 410, height: 560), display: true)
        panel.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        let directory = outputDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        @MainActor func capture(_ name: String) async throws {
            let content = try await SCShareableContent.currentProcess
            guard let window = content.windows.first(where: { $0.windowID == panel.windowNumber }) else { throw NSError(domain: "OwnWindowMissing", code: 1) }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = SCStreamConfiguration()
            configuration.width = Int(panel.frame.width * 2)
            configuration.height = Int(panel.frame.height * 2)
            configuration.ignoreShadowsSingleWindow = true
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            let rep = NSBitmapImageRep(cgImage: image)
            try rep.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
            print("capture \(name) succeeded")
            let view = panel.contentView!
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + "-geometry.png"))
        }
        try await Task.sleep(for: .milliseconds(700))
        try await capture("00-expanded")
        fixture.index = 2
        try await Task.sleep(for: .milliseconds(150))
        try await capture("01-morph")
        fixture.index = 3
        try await Task.sleep(for: .milliseconds(130))
        try await capture("02-interrupted")
        try await Task.sleep(for: .milliseconds(500))
        try await capture("03-settled")
        fixture.index = 2
        try await Task.sleep(for: .milliseconds(500))
        fixture.presentation.setMode(.queue)
        try await Task.sleep(for: .milliseconds(180))
        try await capture("04-queue-midpoint")
        try await Task.sleep(for: .milliseconds(500))
        try await capture("05-queue")
        fixture.presentation.setMode(.compact)
        panel.setFrame(NSRect(x: 100, y: 100, width: 340, height: 88), display: true)
        try await Task.sleep(for: .milliseconds(500))
        try await capture("06-compact")
        fixture.presentation.setMode(.expanded)
        panel.setFrame(NSRect(x: 100, y: 100, width: 390, height: 560), display: true)
        panel.contentView = NSHostingView(rootView: PlayerMotionScene(fixture: fixture).environment(\.colorScheme, .light))
        panel.appearance = NSAppearance(named: .aqua)
        try await Task.sleep(for: .milliseconds(500))
        try await capture("07-light-390")
        panel.contentView = NSHostingView(rootView: PlayerMotionScene(fixture: fixture))
        panel.appearance = NSAppearance(named: .accessibilityHighContrastAqua)
        try await Task.sleep(for: .milliseconds(500))
        try await capture("08-increased-contrast")
        panel.orderOut(nil)
    }
    @MainActor static func runGestures() async throws {
// Run with Xcode RunCodeSnippet in Views/PlayerPreviews.swift context.
let state = GlassProbeState()
let fixture = PlayerMotionFixture()
let panel = StatusPanel(content: GlassGestureScene(state: state, fixture: fixture))
panel.setFrame(NSRect(x: 100, y: 100, width: 410, height: 340), display: true)
panel.makeKeyAndOrderFront(nil)
let directory = outputDirectory.appendingPathComponent("gestures", isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
@MainActor func capture(_ name: String) async throws {
    let content = try await SCShareableContent.currentProcess
    let window = content.windows.first { $0.windowID == panel.windowNumber }!
    let configuration = SCStreamConfiguration()
    configuration.width = 820
    configuration.height = 680
    configuration.ignoreShadowsSingleWindow = true
    let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration)
    let bitmap = NSBitmapImageRep(cgImage: image)
    try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
}
@MainActor func mouse(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) {
    let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 340-y), modifierFlags: [],
                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                                  context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
    panel.sendEvent(event)
}
func settle(_ milliseconds: Int = 80) async throws { try await Task.sleep(for: .milliseconds(milliseconds)) }
try await settle(300)
try await capture("00-idle")
mouse(.leftMouseDown, 342, 165)
try await settle(50)
mouse(.leftMouseUp, 342, 165)
try await settle()
print("quick click seeks=\(state.seeks)")
mouse(.leftMouseDown, 342, 165)
try await settle(550)
try await capture("01-held-scrubber")
mouse(.leftMouseUp, 342, 165)
try await settle()
print("held right seeks=\(state.seeks)")
try await settle(220)
try await capture("02-released")
mouse(.leftMouseDown, 68, 165)
try await settle(300)
mouse(.leftMouseDragged, 205, 28)
mouse(.leftMouseUp, 205, 28)
try await settle()
print("held left to top seeks=\(state.seeks)")
mouse(.leftMouseDown, 342, 165)
try await settle(300)
state.canSeek = false
try await settle()
mouse(.leftMouseUp, 342, 165)
try await settle()
print("disabled while held seeks=\(state.seeks)")
state.canSeek = true
try await settle()
mouse(.leftMouseDown, 342, 165)
try await settle(300)
state.occurrence = "replacement"
try await settle()
mouse(.leftMouseUp, 342, 165)
try await settle()
print("track replaced seeks=\(state.seeks)")
mouse(.leftMouseDown, 205, 165)
try await settle(50)
mouse(.leftMouseDragged, 130, 165)
mouse(.leftMouseUp, 130, 165)
try await settle()
print("unheld album drag skips=\(state.skips)")
mouse(.leftMouseDown, 205, 165)
try await settle(550)
try await capture("03-album-held")
mouse(.leftMouseDragged, 204, 165)
try await settle(20)
mouse(.leftMouseDragged, 170, 165)
try await settle(20)
mouse(.leftMouseDragged, 130, 165)
try await settle(80)
try await capture("04-album-dragged")
mouse(.leftMouseUp, 130, 165)
try await settle(300)
print("held album left skips=\(state.skips)")
try await capture("05-album-released")
mouse(.leftMouseDown, 205, 165)
try await settle(300)
mouse(.leftMouseDragged, 206, 165)
try await settle(20)
mouse(.leftMouseDragged, 280, 165)
mouse(.leftMouseUp, 280, 165)
try await settle()
print("held album right skips=\(state.skips)")
mouse(.leftMouseDown, 205, 165)
try await settle(300)
mouse(.leftMouseDragged, 204, 165)
try await settle(20)
mouse(.leftMouseDragged, 180, 165)
mouse(.leftMouseUp, 180, 165)
try await settle()
print("short album drag skips=\(state.skips)")
mouse(.leftMouseDown, 205, 165)
try await settle(300)
fixture.index = 2
try await settle(500)
mouse(.leftMouseDragged, 204, 165)
try await settle(20)
mouse(.leftMouseDragged, 130, 165)
mouse(.leftMouseUp, 130, 165)
try await settle()
print("album replaced during hold skips=\(state.skips)")
mouse(.leftMouseDown, 205, 165)
try await settle(300)
state.canNext = false
try await settle()
state.canNext = true
try await settle()
mouse(.leftMouseDragged, 204, 165)
try await settle(20)
mouse(.leftMouseDragged, 130, 165)
mouse(.leftMouseUp, 130, 165)
try await settle()
print("album control lost during hold skips=\(state.skips)")
state.canSeek = false
try await settle()
state.canSeek = true
try await settle()
mouse(.leftMouseDown, 342, 165)
try await settle(300)
mouse(.leftMouseUp, 342, 165)
try await settle()
print("idle control restored seeks=\(state.seeks)")
state.durationMs = 120_000
try await settle()
mouse(.leftMouseDown, 342, 165)
try await settle(300)
mouse(.leftMouseUp, 342, 165)
try await settle()
print("idle duration changed seeks=\(state.seeks)")
mouse(.leftMouseDown, 205, 165)
try await settle(300)
state.replacementTrack = Track(uri: SpotifyURI("spotify:track:metadata-first")!, title: "Replacement", artists: [], albumTitle: nil, artwork: nil, durationMs: 120_000)
try await settle()
mouse(.leftMouseDragged, 204, 165)
try await settle(20)
mouse(.leftMouseDragged, 130, 165)
mouse(.leftMouseUp, 130, 165)
try await settle()
print("metadata changed before queue skips=\(state.skips)")
precondition(state.seeks == [75000, 50000, 75000, 90000] && state.skips == 1)
print("PASS=\(state.seeks == [75000, 50000, 75000, 90000] && state.skips == 1)")
print("Gesture captures: \(directory.path)")
panel.orderOut(nil)

    }
}
