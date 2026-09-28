import SwiftUI
import ScreenCaptureKit
import BopifyPlayback
import BopifyDomain

private struct ProbePlayerScene: View {
    let player: PlayerModel
    let environment: AppEnvironment
    let presentation: PlayerPresentation
    let controller: MonolithWindowController
    let store = previewArtworkStore()
    var body: some View {
        MonolithPlayerView(player: player, store: store, presentation: presentation, window: controller)
            .environment(\.favoriteEnvironment, environment)
            .onChange(of: presentation.mode) { _, mode in controller.apply(mode: mode, reduceMotion: false) }
    }
}

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
        let panel = StatusPanel(content: ProbePlayerScene(player: player, environment: environment, presentation: presentation, controller: controller))
        let backdrop = StatusPanel(content: Color.clear)
        backdrop.setFrame(CGRect(x: 0, y: 0, width: 1000, height: 800), display: false)
        backdrop.backgroundColor = NSColor(calibratedRed: 0.12, green: 0.22, blue: 0.20, alpha: 1)
        backdrop.orderFrontRegardless()
        controller.attach(to: panel)
        panel.onKeyChanged = { presentation.sendAttention(.keyboardFocus($0)) }
        defer { panel.orderOut(nil); backdrop.orderOut(nil) }
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
        let restingButtons = accessibilityTree(panel.contentView!).filter { attribute($0, "accessibilityRole") as? String == "AXButton" }
        print("resting AX buttons: \(restingButtons.map { attribute($0, "accessibilityLabel") as? String ?? "" })")
        precondition(!restingButtons.contains { attribute($0, "accessibilityLabel") as? String == "Next" || attribute($0, "accessibilityLabel") as? String == "Play" }, "hidden controls leave accessibility navigation")
        var statusFailures: [String] = []
        for (event, expected) in [(PlaybackEvent.playing(positionMs: 1545), "Playing"),
                                  (.loading, "Loading…"), (.endOfTrack, "Finished"),
                                  (.activeDeviceChanged(isActive: false), "Not playing"),
                                  (.failed(.playbackSessionLost), String(localized: "error.playbackSessionLost")),
                                  (.paused(positionMs: 1545), "Paused")] {
            engine.emit(event)
            try await settle(100)
            #if MONOLITH_MEASURE
            if expected == "Not playing" { try await verifyAmbientStopped("inactive") }
            #endif
            let record = accessibilityTree(panel.contentView!).first { attribute($0, "accessibilityLabel") as? String == "Afterglow" }!
            let actual = attribute(record, "accessibilityValue") as? String
            print("record status: \(actual ?? "nil"), expected: \(expected)")
            if actual != expected { statusFailures.append(expected) }
        }
        let beforeError = try await capture(panel, "player-resting-before-error")
        engine.emit(.failed(.networkUnavailable))
        try await settle(100)
        let errorRecord = accessibilityTree(panel.contentView!).first { attribute($0, "accessibilityLabel") as? String == "Afterglow" }!
        if attribute(errorRecord, "accessibilityValue") as? String != "No network connection." { statusFailures.append("network error description") }
        let afterError = try await capture(panel, "player-resting-error")
        if orangeRimPixels(afterError) <= orangeRimPixels(beforeError) + 80 { statusFailures.append("active-device error rim") }
        precondition(player.state.isActiveDevice && presentation.mode == .compact && engine.recordedCommands.isEmpty,
                     "status changes neither reveal nor issue commands")
        presentation.sendAttention(.keyboardFocus(true))
        try await settle()
        let erroredPlayButton = accessibilityTree(panel.contentView!).first { attribute($0, "accessibilityLabel") as? String == "Play" }!
        if attribute(erroredPlayButton, "accessibilityValue") as? String != "No network connection." { statusFailures.append("play control error description") }
        presentation.sendAttention(.keyboardFocus(false))
        try await settle()
        engine.emit(.commandRejected("staleQueue"))
        try await settle(100)
        let noticeRecord = accessibilityTree(panel.contentView!).first { attribute($0, "accessibilityLabel") as? String == "Afterglow" }!
        if attribute(noticeRecord, "accessibilityValue") as? String != player.commandNotice { statusFailures.append("command notice") }
        print("status failures: \(statusFailures)")
        fflush(nil)
        precondition(statusFailures.isEmpty, "record describes authoritative status and marks errors")
        engine.emit(.queueChanged(PlaybackQueue(generation: 0, previous: [], current: nil, next: [])))
        engine.emit(.paused(positionMs: 1545))
        try await settle(100)
        let recordButton = restingButtons.first { attribute($0, "accessibilityLabel") as? String == "Afterglow" }!
        let press = NSSelectorFromString("accessibilityPerformPress")
        typealias AccessibilityPress = @convention(c) (AnyObject, Selector) -> Bool
        let performPress = unsafeBitCast(recordButton.method(for: press), to: AccessibilityPress.self)
        precondition(performPress(recordButton, press), "record exposes its accessibility action")
        try await settle()
        precondition(panel.isKeyWindow, "accessibility activation acquires native keyboard focus")
        backdrop.makeKeyAndOrderFront(nil)
        try await settle()
        precondition(presentation.mode == .compact, "native focus loss releases accessibility activation hold")
        presentation.sendAttention(.keyboardFocus(true))
        controller.apply(mode: presentation.mode, reduceMotion: false)
        panel.makeKeyAndOrderFront(nil)
        try await settle()
        precondition(panel.isKeyWindow && presentation.mode == .expanded, "native focus reveals controls")
        try await capture(panel, "player-focused")
        let focusedButtons = accessibilityTree(panel.contentView!).filter { attribute($0, "accessibilityRole") as? String == "AXButton" }
        print("focused AX buttons: \(focusedButtons.map { attribute($0, "accessibilityLabel") as? String ?? "" })")
        fflush(nil)
        precondition(focusedButtons.contains { attribute($0, "accessibilityLabel") as? String == "Play" }, "focused controls enter accessibility navigation")
        presentation.requestQueue(true)
        controller.apply(mode: presentation.mode, reduceMotion: false)
        try await settle()
        try await capture(panel, "player-queue-loading")
        precondition(engine.recordedCommands.isEmpty, "revealing and focusing never issue playback commands")
        presentation.requestQueue(false)
        try await settle()
        func mouse(_ type: NSEvent.EventType, at point: CGPoint) {
            let screen = panel.convertPoint(toScreen: CGPoint(x: point.x, y: panel.frame.height - point.y))
            let eventType: CGEventType = type == .leftMouseDown ? .leftMouseDown : type == .leftMouseDragged ? .leftMouseDragged : .leftMouseUp
            CGEvent(mouseEventSource: nil, mouseType: eventType,
                    mouseCursorPosition: CGPoint(x: screen.x, y: NSScreen.screens[0].frame.maxY - screen.y), mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        let center = controller.layout.recordCenter
        let ring = CGPoint(x: center.x, y: center.y - controller.layout.recordDiameter / 2 + 8)
        let right = CGPoint(x: center.x + controller.layout.recordDiameter / 2 - 8, y: center.y)
        let originBeforeScrub = panel.frame.origin
        mouse(.leftMouseDown, at: ring)
        try await settle(50)
        mouse(.leftMouseUp, at: ring)
        try await settle(80)
        precondition(engine.recordedCommands.isEmpty, "quick ring click cannot seek")
        mouse(.leftMouseDown, at: ring)
        try await settle(80)
        mouse(.leftMouseDragged, at: right)
        try await settle(80)
        mouse(.leftMouseUp, at: right)
        try await settle(80)
        precondition(engine.recordedCommands == ["seek:16545"], "clockwise quarter turn commits one relative 15-second seek")
        mouse(.leftMouseDown, at: ring)
        try await settle(80)
        mouse(.leftMouseDragged, at: right)
        try await settle(80)
        engine.emit(.activeDeviceChanged(isActive: false))
        try await settle(80)
        mouse(.leftMouseUp, at: ring)
        try await settle(80)
        precondition(engine.recordedCommands == ["seek:16545"], "capability loss cancels a held seek")
        engine.emit(.paused(positionMs: 1545))
        try await settle(80)
        mouse(.leftMouseDown, at: ring)
        try await settle(80)
        mouse(.leftMouseDragged, at: right)
        try await settle(80)
        engine.emit(.queueChanged(PlaybackQueue(generation: 1, previous: [], current: QueueEntry(id: "replacement", uri: track.uri, target: nil, track: track, metadataFailed: false), next: [])))
        try await settle(80)
        mouse(.leftMouseUp, at: ring)
        try await settle(80)
        precondition(engine.recordedCommands == ["seek:16545"], "occurrence replacement cancels a held seek")
        mouse(.leftMouseDown, at: ring)
        try await settle(80)
        mouse(.leftMouseDragged, at: right)
        try await settle(80)
        presentation.isVisible = false
        try await settle(80)
        mouse(.leftMouseUp, at: ring)
        try await settle(80)
        precondition(engine.recordedCommands == ["seek:16545"], "hiding cancels a held seek")
        presentation.isVisible = true
        presentation.sendAttention(.keyboardFocus(true))
        try await settle()
        mouse(.leftMouseDown, at: center)
        mouse(.leftMouseUp, at: center)
        try await settle(80)
        precondition(engine.recordedCommands == ["seek:16545"], "center click has no playback command")
        precondition(panel.frame.origin == originBeforeScrub, "record dragging never moves the window")
        let current = QueueEntry(id: "a", uri: track.uri, target: nil, track: track, metadataFailed: false)
        let next = QueueEntry(id: "b", uri: track.uri, target: QueueTarget(generation: 2, rawNextIndex: 0), track: track, metadataFailed: false)
        engine.emit(.queueChanged(PlaybackQueue(generation: 2, previous: [], current: current, next: [next])))
        try await settle(80)
        presentation.requestQueue(true)
        try await settle()
        try await capture(panel, "player-queue")
        let rowPoint = CGPoint(x: controller.layout.lowerFrame.midX, y: controller.layout.lowerFrame.minY + 98)
        mouse(.leftMouseDown, at: rowPoint)
        mouse(.leftMouseUp, at: rowPoint)
        try await settle(100)
        precondition(player.queueSelection == .pending(entryID: next.id, target: next.target!), "row selects exact occurrence")
        precondition(presentation.mode == .queue, "dispatch alone keeps queue open")
        engine.emit(.queueChanged(PlaybackQueue(generation: 3, previous: [current], current: QueueEntry(id: next.id, uri: track.uri, target: nil, track: track, metadataFailed: false), next: [])))
        try await settle()
        precondition(presentation.mode == .expanded, "confirmed occurrence closes the queue extension")
        precondition(controller.layout.contentSize.height == 360 && panel.frame.height == 360, "confirmed selection preserves lower-panel geometry")
        try await capture(panel, "player-confirmed-selection")
        let delayed = QueueEntry(id: "c", uri: track.uri, target: QueueTarget(generation: 4, rawNextIndex: 0), track: track, metadataFailed: false)
        engine.emit(.queueChanged(PlaybackQueue(generation: 4, previous: [], current: current, next: [delayed])))
        try await settle(80)
        presentation.requestQueue(true)
        try await settle()
        mouse(.leftMouseDown, at: rowPoint)
        mouse(.leftMouseUp, at: rowPoint)
        try await settle(80)
        precondition(player.queueSelection == .pending(entryID: delayed.id, target: delayed.target!))
        presentation.requestQueue(false)
        try await settle()
        presentation.requestQueue(true)
        try await settle()
        engine.emit(.queueChanged(PlaybackQueue(generation: 5, previous: [], current: QueueEntry(id: delayed.id, uri: track.uri, target: nil, track: track, metadataFailed: false), next: [])))
        try await settle()
        precondition(presentation.mode == .queue, "late confirmation cannot close a reopened queue")
        try await capture(panel, "player-queue-empty")
        engine.emit(.commandRejected("staleQueue"))
        try await settle(80)
        try await capture(panel, "player-queue-rejected")
        presentation.requestQueue(false)
        try await settle()
        backdrop.backgroundColor = NSColor(calibratedRed: 0.83, green: 0.81, blue: 0.73, alpha: 1)
        panel.appearance = NSAppearance(named: .aqua)
        try await settle()
        try await capture(panel, "player-light")
        panel.appearance = NSAppearance(named: .accessibilityHighContrastAqua)
        try await settle()
        try await capture(panel, "player-high-contrast")
        controller.apply(mode: .expanded, reduceMotion: true, visibleFrame: CGRect(x: 200, y: 100, width: 320, height: 480))
        try await settle()
        precondition(panel.frame.width == 320 && controller.layout.controlsFrame.width >= 144)
        try await capture(panel, "player-narrow")
        engine.emit(.queueChanged(PlaybackQueue(generation: 6, previous: [], current: nil, next: [])))
        engine.emit(.trackChanged(Track(uri: track.uri, title: "宇宙の静寂 — A Very Long Track Title Across the Evening Sky", artists: [ArtistSummary(name: "An Artist with an Equally Long Name")], albumTitle: nil, artwork: nil, durationMs: 240_000)))
        try await settle()
        try await capture(panel, "player-narrow-long-metadata")
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

    @MainActor static func attribute(_ value: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        guard value.responds(to: selector) else { return nil }
        return value.perform(selector)?.takeUnretainedValue()
    }
    @MainActor static func accessibilityTree(_ value: Any) -> [NSObject] {
        guard let element = value as? NSObject else { return [] }
        return [element] + ((attribute(element, "accessibilityChildren") as? [Any]) ?? []).flatMap { accessibilityTree($0) }
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
        #if MONOLITH_MEASURE
        let playingTicks = MonolithAmbientProbe.ticks
        try await settle(300)
        precondition(MonolithAmbientProbe.ticks > playingTicks, "playing record advances")
        print("ambient playing ticks in 300 ms: \(MonolithAmbientProbe.ticks - playingTicks)")
        #endif
        fixture.playing = false
        try await settle()
        try await capture(panel, "record-paused")
        #if MONOLITH_MEASURE
        try await verifyAmbientStopped("paused")
        #endif
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
        fixture.playing = true
        fixture.index = 1
        fixture.occurrenceID = "reduced"
        try await settle(80)
        try await capture(panel, "record-reduced-motion")
        #if MONOLITH_MEASURE
        try await settle(300)
        try await verifyAmbientStopped("reduced-motion")
        #endif
        fixture.reducedMotion = false
        fixture.visible = false
        try await settle()
        #if MONOLITH_MEASURE
        try await verifyAmbientStopped("hidden")
        #endif
    }

    #if MONOLITH_MEASURE
    @MainActor static func verifyAmbientStopped(_ name: String) async throws {
        let ticks = MonolithAmbientProbe.ticks
        try await settle(300)
        print("ambient \(name) ticks in 300 ms: \(MonolithAmbientProbe.ticks - ticks)")
        precondition(MonolithAmbientProbe.ticks == ticks, "settled \(name) record has no timer updates")
    }
    #endif

    @MainActor static func settle(_ milliseconds: Int = 800) async throws {
        try await Task.sleep(for: .milliseconds(milliseconds))
    }
    @MainActor static func orangeRimPixels(_ image: CGImage) -> Int {
        let bitmap = NSBitmapImageRep(cgImage: image)
        var count = 0
        for y in 0..<image.height {
            for x in 0..<image.width where abs(hypot(Double(x) - 142, Double(y) - 142) - 118) <= 4 {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.alphaComponent > 0.2 && color.redComponent > 0.5 && color.greenComponent > 0.15
                    && color.redComponent > color.greenComponent * 1.15 && color.greenComponent > color.blueComponent * 1.3 { count += 1 }
            }
        }
        return count
    }

    @discardableResult @MainActor static func capture(_ panel: StatusPanel, _ name: String) async throws -> CGImage {
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
        return image
    }
}
