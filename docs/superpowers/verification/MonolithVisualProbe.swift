import SwiftUI
import ScreenCaptureKit
import BopifyPlayback

@main struct MonolithVisualProbe {
    static var output: URL { URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true) }
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        Task { @MainActor in
            do { try await recordFixtures(); print("MONOLITH VISUAL PASS"); app.terminate(nil) }
            catch { print("MONOLITH VISUAL FAIL: \(error)"); exit(1) }
        }
        app.run()
    }

    @MainActor static func recordFixtures() async throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let fixture = MonolithRecordFixture()
        let panel = StatusPanel(content: MonolithRecordScene(fixture: fixture))
        panel.setFrame(CGRect(x: 240, y: 300, width: 264, height: 264), display: true)
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        try await settle()
        try await capture(panel, "record-playing")
        fixture.playing = false
        try await settle()
        try await capture(panel, "record-paused")
        fixture.missing = true
        try await settle()
        try await capture(panel, "record-missing")
        fixture.missing = false
        fixture.diameter = 118
        try await settle()
        try await capture(panel, "record-resting")
        fixture.diameter = 182
        fixture.occurrenceID = "same-cover-duplicate"
        try await settle(120)
        try await capture(panel, "record-duplicate-transition")
        fixture.index = 2
        fixture.occurrenceID = "next"
        try await settle(90)
        try await capture(panel, "record-next")
        fixture.index = 0
        fixture.direction = .previous
        fixture.occurrenceID = "previous"
        try await settle(60)
        try await capture(panel, "record-interrupted")
        try await settle()
        try await capture(panel, "record-settled")
        fixture.reducedMotion = true
        fixture.index = 1
        fixture.occurrenceID = "reduced"
        try await settle(80)
        try await capture(panel, "record-reduced-motion")
        fixture.visible = false
        try await settle()
    }

    @MainActor static func settle(_ milliseconds: Int = 800) async throws {
        try await Task.sleep(for: .milliseconds(milliseconds))
    }
    @MainActor static func capture(_ panel: StatusPanel, _ name: String) async throws {
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
        print("capture: \(name)")
    }
}
