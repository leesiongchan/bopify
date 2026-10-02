import SwiftUI
import ScreenCaptureKit
import BopifyDomain
import BopifyPlayback

@main struct MonolithSurfaceProbe {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        Task { @MainActor in
            do { try await run(); print("MONOLITH SURFACE PASS"); app.terminate(nil) }
            catch { print("MONOLITH SURFACE FAIL: \(error)"); exit(1) }
        }
        app.run()
    }

    @MainActor static func run() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let screen = NSScreen.main!
        let area = CGRect(x: screen.visibleFrame.midX - 330, y: screen.visibleFrame.midY - 240, width: 660, height: 480)
        let backdrop = NSWindow(contentRect: area, styleMask: [.borderless], backing: .buffered, defer: false)
        backdrop.hasShadow = false
        backdrop.orderFrontRegardless()
        let defaults = UserDefaults(suiteName: "monolith.surface.\(UUID())")!
        defaults.set(NSStringFromPoint(CGPoint(x: area.minX + 150, y: area.maxY - 190)), forKey: "player.recordCenter")
        let controller = PlayerWindowController(defaults: defaults)
        let presentation = PlayerPresentation()
        let engine = StubPlaybackEngine()
        let player = PlayerModel(engine: engine)
        player.start()
        let store = previewArtworkStore()
        let panel = StatusPanel(content: RecordPlayerView(player: player, store: store, presentation: presentation, window: controller))
        controller.attach(to: panel)
        presentation.isVisible = true
        presentation.sendAttention(.keyboardFocus(true))
        controller.apply(mode: .expanded, reduceMotion: true)
        engine.emit(.trackChanged(Track(uri: SpotifyURI("spotify:track:surface")!, title: "Afterglow",
            artists: [ArtistSummary(name: "The Evening Hours")], albumTitle: nil, artwork: nil, durationMs: 240_000)))
        engine.emit(.paused(positionMs: 1545))
        if ProcessInfo.processInfo.environment["MONOLITH_CAPTURE_SCENE"] == "1" {
            backdrop.addChildWindow(panel, ordered: .above)
        }
        panel.makeKeyAndOrderFront(nil)
        defer { player.stop(); panel.orderOut(nil); backdrop.orderOut(nil) }
        for dark in [false, true] {
            backdrop.backgroundColor = dark ? NSColor(calibratedRed: 0.06, green: 0.09, blue: 0.14, alpha: 1) : NSColor(calibratedRed: 0.88, green: 0.92, blue: 0.96, alpha: 1)
            panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for shadow in [true, false] {
                panel.hasShadow = shadow
                panel.invalidateShadow()
                try await Task.sleep(for: .milliseconds(600))
                let content = try await SCShareableContent.currentProcess
                guard let window = content.windows.first(where: { $0.windowID == panel.windowNumber }) else {
                    throw NSError(domain: "surface fixture window unavailable", code: 1)
                }
                let config = SCStreamConfiguration()
                config.width = Int(panel.frame.width * 2)
                config.height = Int(panel.frame.height * 2)
                config.showsCursor = false
                config.ignoreShadowsSingleWindow = false
                let filter: SCContentFilter
                if ProcessInfo.processInfo.environment["MONOLITH_CAPTURE_SCENE"] == "1" {
                    let background = content.windows.first { $0.windowID == backdrop.windowNumber }!
                    filter = SCContentFilter(desktopIndependentWindow: background)
                    config.includeChildWindows = true
                    config.width = Int(area.width * 2); config.height = Int(area.height * 2)
                } else {
                    filter = SCContentFilter(desktopIndependentWindow: window)
                }
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                let name = "surface-\(dark ? "dark" : "light")-\(shadow ? "shadow" : "no-shadow").png"
                try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
                print("CAPTURE: \(name)")
            }
        }
    }
}
