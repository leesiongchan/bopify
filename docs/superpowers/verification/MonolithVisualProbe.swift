import SwiftUI
import ScreenCaptureKit
import BopifyPlayback
import BopifyDomain

@main struct MonolithVisualProbe {
    static var output: URL { URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true) }
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        Task { @MainActor in
            do { try await recordFixtures(); try await playerFixtures(); print("MONOLITH VISUAL PASS"); app.terminate(nil) }
            catch { print("MONOLITH VISUAL FAIL: \(error)"); exit(1) }
        }
        app.run()
    }

    @MainActor static func playerFixtures() async throws {
        let engine = StubPlaybackEngine()
        let player = PlayerModel(engine: engine)
        player.start()
        defer { player.stop() }
        let presentation = PlayerPresentation()
        let controller = MonolithWindowController(defaults: UserDefaults(suiteName: "monolith.visual.\(UUID())")!)
        let environment = AppEnvironment(previewPlayer: player, favoriteService: PreviewLibrary())
        let panel = StatusPanel(content: MonolithPlayerView(player: player, store: previewArtworkStore(), presentation: presentation, window: controller)
            .environment(\.favoriteEnvironment, environment)
            .onChange(of: presentation.mode) { _, mode in controller.apply(mode: mode, reduceMotion: false) })
        controller.attach(to: panel)
        defer { panel.orderOut(nil) }
        precondition(PlayerContent(player.state) == .loading)
        engine.emit(.startupResolved(.restored))
        try await settle(70)
        precondition(PlayerContent(player.state) == .loading)
        let track = Track(uri: SpotifyURI("spotify:track:fixture")!, title: "Afterglow", artists: [ArtistSummary(name: "The Evening Hours")], albumTitle: nil, artwork: Artwork(url: previewArtworkURL(1)), durationMs: 240_000)
        engine.emit(.trackChanged(track))
        engine.emit(.paused(positionMs: 1545))
        try await settle(70)
        await environment.refreshFavorite()
        precondition(player.state.positionMs == 1545 && player.state.phase == .paused)
        presentation.sendAttention(.visibility(true))
        controller.apply(mode: .compact, reduceMotion: true)
        panel.orderFrontRegardless()
        try await settle()
        try await capture(panel, "player-resting")
        presentation.sendAttention(.keyboardFocus(true))
        controller.apply(mode: presentation.mode, reduceMotion: false)
        try await settle()
        try await capture(panel, "player-focused")
        presentation.requestQueue(true)
        controller.apply(mode: presentation.mode, reduceMotion: false)
        try await settle()
        try await capture(panel, "player-queue-loading")
        precondition(engine.recordedCommands.isEmpty, "revealing and focusing never issue playback commands")
        presentation.requestQueue(false)
        try await settle()
        func mouse(_ type: NSEvent.EventType, at point: CGPoint) {
            let event = NSEvent.mouseEvent(with: type, location: CGPoint(x: point.x, y: panel.frame.height - point.y),
                                          modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: panel.windowNumber, context: nil, eventNumber: 0,
                                          clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
            panel.sendEvent(event)
        }
        let center = controller.layout.recordCenter
        let ring = CGPoint(x: center.x + controller.layout.recordDiameter / 2, y: center.y)
        mouse(.leftMouseDown, at: ring)
        try await settle(50)
        mouse(.leftMouseUp, at: ring)
        try await settle(80)
        precondition(engine.recordedCommands.isEmpty, "quick ring click cannot seek")
        mouse(.leftMouseDown, at: ring)
        try await settle(350)
        mouse(.leftMouseUp, at: ring)
        try await settle(80)
        precondition(engine.recordedCommands == ["seek:60000"], "held right rim commits one quarter-duration seek")
        mouse(.leftMouseDown, at: ring)
        try await settle(350)
        engine.emit(.activeDeviceChanged(isActive: false))
        try await settle(80)
        mouse(.leftMouseUp, at: ring)
        try await settle(80)
        precondition(engine.recordedCommands == ["seek:60000"], "capability loss cancels a held seek")
        engine.emit(.paused(positionMs: 1545))
        try await settle(80)
        mouse(.leftMouseDown, at: ring)
        try await settle(350)
        engine.emit(.queueChanged(PlaybackQueue(generation: 1, previous: [], current: QueueEntry(id: "replacement", uri: track.uri, target: nil, track: track, metadataFailed: false), next: [])))
        try await settle(80)
        mouse(.leftMouseUp, at: ring)
        try await settle(80)
        precondition(engine.recordedCommands == ["seek:60000"], "occurrence replacement cancels a held seek")
        mouse(.leftMouseDown, at: ring)
        try await settle(350)
        presentation.isVisible = false
        try await settle(80)
        mouse(.leftMouseUp, at: ring)
        try await settle(80)
        precondition(engine.recordedCommands == ["seek:60000"], "hiding cancels a held seek")
        presentation.isVisible = true
        presentation.sendAttention(.keyboardFocus(true))
        try await settle()
        mouse(.leftMouseDown, at: center)
        mouse(.leftMouseUp, at: center)
        try await settle(80)
        precondition(engine.recordedCommands == ["seek:60000"], "center click has no playback command")
        let remoteEngine = StubPlaybackEngine()
        let remote = PlayerModel(engine: remoteEngine)
        remote.start()
        defer { remote.stop() }
        remoteEngine.emit(.startupResolved(.remote(deviceName: "iPhone")))
        try await settle(70)
        precondition(PlayerContent(remote.state) == .remote(deviceName: "iPhone"))
        remoteEngine.emit(.failed(.networkUnavailable))
        try await settle(70)
        precondition(PlayerContent(remote.state) == .player && remote.state.currentTrack == nil)
        precondition(remoteEngine.recordedCommands.isEmpty)
    }

    private struct PreviewLibrary: LibraryService {
        func savedState(for uri: SpotifyURI) async throws -> Bool { false }
        func save(_ uri: SpotifyURI) async throws {}
        func remove(_ uri: SpotifyURI) async throws {}
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
