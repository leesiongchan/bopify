import SwiftUI
import ScreenCaptureKit
import Observation
import BopifyDomain
import BopifyPlayback

private actor PressingPaletteGate {
    private(set) var count = 0
    private var waiting: [Int: CheckedContinuation<ArtworkPalette?, Never>] = [:]
    func extract(_ image: CGImage) async -> ArtworkPalette? {
        count += 1
        let ordinal = count
        return await withCheckedContinuation { waiting[ordinal] = $0 }
    }
    func release(_ ordinal: Int, _ palette: ArtworkPalette?) { waiting.removeValue(forKey: ordinal)!.resume(returning: palette) }
}

private nonisolated final class PressingArtworkProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var data = Data()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "pressing.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let status = request.url!.path == "/http-failure" ? 503 : 200
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Observable private final class PressingProbeSettings {
    var reduceMotion = false
    var mounted = true
    var artworkStore: ArtworkStore?
    var reduceTransparency = false
    var increasedContrast = false
}

private struct PressingProbeScene: View {
    let environment: AppEnvironment
    let presentation: PlayerPresentation
    let controller: PlayerWindowController
    let settings: PressingProbeSettings
    var body: some View {
        if settings.mounted {
            RecordPlayerView(player: environment.player!, artworkStore: settings.artworkStore ?? environment.artworkStore,
                             presentation: presentation, windowController: controller)
                .environment(environment)
                // Writable backing keys in the Xcode 27 SDK let the fixture exercise the production environment reads.
                .environment(\._accessibilityReduceMotion, settings.reduceMotion)
                .environment(\._accessibilityReduceTransparency, settings.reduceTransparency)
                .environment(\._colorSchemeContrast, settings.increasedContrast ? .increased : .standard)
                .id(ObjectIdentifier(settings.artworkStore ?? environment.artworkStore))
        }
    }
}

@main struct VinylPressingProbe {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        Task { @MainActor in
            do { try await run(); print("VINYL PRESSING PASS"); app.terminate(nil) }
            catch { print("VINYL PRESSING FAIL: \(error)"); fflush(stdout); exit(1) }
        }
        app.run()
    }

    static func run() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let environment = makePreviewEnvironment(.playing, library: .samples)
        let player = environment.player!
        let presentation = PlayerPresentation()
        presentation.isVisible = true
        presentation.sendAttention(.keyboardFocus(true))
        let controller = PlayerWindowController(defaults: UserDefaults(suiteName: "vinyl.probe.\(UUID())")!)
        let settings = PressingProbeSettings()
        let panel = StatusPanel(content: PressingProbeScene(environment: environment, presentation: presentation,
                                                           controller: controller, settings: settings))
        controller.attach(to: panel)
        controller.apply(mode: .expanded, reduceMotion: true)
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.makeKeyAndOrderFront(nil)
        defer { player.stop(); panel.orderOut(nil) }
        try await settle(1000)
        if let seconds = Double(ProcessInfo.processInfo.environment["VINYL_PROBE_HOLD_SECONDS"] ?? "") {
            print("GPU CONTROL: expanded 182pt, dark, scale \(panel.backingScaleFactor), \(seconds)s"); fflush(stdout)
            try await Task.sleep(for: .seconds(seconds))
            return
        }
        player.applyPreviewEvents([.paused(positionMs: 64_000)])
        try await settle(900)
        for dark in [false, true] {
            panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for mode in [PlayerMode.compact, .expanded] {
                controller.apply(mode: mode, reduceMotion: true)
                try await settle(800)
                let image = try await capture(panel, output: output, name: "\(ProcessInfo.processInfo.environment["VINYL_PROBE_BASELINE"] == "1" ? "baseline" : "pressing")-\(Int(controller.layout.recordDiameter))-\(dark ? "dark" : "light")")
                if dark && mode == .expanded && ProcessInfo.processInfo.environment["VINYL_PROBE_BASELINE"] != "1" {
                    let fraction = saturatedFraction(image, center: controller.layout.recordCenter, diameter: controller.layout.recordDiameter)
                    try require(fraction > 0.2, "colourful artwork must colour the pressing annulus; got \(fraction)")
                }
            }
        }
        if ProcessInfo.processInfo.environment["VINYL_PROBE_BASELINE"] == "1" { return }
        #if MONOLITH_MEASURE
        try await verifyPressings(player: player, environment: environment, settings: settings, panel: panel, controller: controller, output: output)
        try await visualMatrix(player: player, settings: settings, panel: panel, controller: controller, output: output)
        if ProcessInfo.processInfo.environment["VINYL_PROBE_VISUAL_ONLY"] == "1" { return }
        try await verifyMotor(player: player, presentation: presentation, settings: settings, panel: panel)
        try await verifyEngineStops()
        #endif
    }

    #if MONOLITH_MEASURE
    private static func visualMatrix(player: PlayerModel, settings: PressingProbeSettings, panel: StatusPanel,
                                     controller: PlayerWindowController, output: URL) async throws {
        let originals = makePreviewArtworkStore()
        var images = originals.images
        let grayURL = previewArtworkURL(3)
        let renderer = ImageRenderer(content: LinearGradient(colors: [.black, .gray, .white],
            startPoint: .topLeading, endPoint: .bottomTrailing).frame(width: 240, height: 240))
        images[grayURL] = renderer.nsImage!
        settings.artworkStore = ArtworkStore(previewImages: images)
        var generation: UInt64 = 100
        for dark in [false, true] {
            panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for mode in [PlayerMode.compact, .expanded] {
                controller.apply(mode: mode, reduceMotion: true)
                for (name, url) in [("colourful", previewArtworkURL(1)), ("warm-attention", previewArtworkURL(2)),
                                    ("greyscale", grayURL), ("missing", nil)] {
                    generation += 1
                    let track = Track(uri: SpotifyURI("spotify:track:matrix\(name.filter(\.isLetter))")!,
                        title: name, artists: [ArtistSummary(name: "Native fixture")], albumTitle: nil,
                        artwork: url.map(Artwork.init(url:)), durationMs: 240_000)
                    player.applyPreviewEvents([.queueChanged(PlaybackQueue(generation: generation, previous: [],
                        current: QueueEntry(id: name, uri: track.uri, target: nil, track: track, metadataFailed: false), next: [])),
                        .trackChanged(track), .paused(positionMs: 0)])
                    if name == "warm-attention" { player.applyPreviewEvents([.failed(.networkUnavailable)]) }
                    try await settle(850)
                    let captureName = "matrix-\(name)-\(Int(controller.layout.recordDiameter))-\(dark ? "dark" : "light")"
                    let image = try await capture(panel, output: output, name: captureName)
                    let fraction = saturatedFraction(image, center: controller.layout.recordCenter, diameter: controller.layout.recordDiameter)
                    try require(name == "colourful" || name == "warm-attention" ? fraction > 0.2 : fraction < 0.08,
                                "\(name) annulus classification disagrees with artwork: \(fraction)")
                    if let comparison = ProcessInfo.processInfo.environment["VINYL_PROBE_COMPARE_DIR"] {
                        let previous = NSImage(contentsOfFile: comparison + "/" + captureName + ".png")!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
                        let difference = annulusDifference(previous, image, center: controller.layout.recordCenter, diameter: controller.layout.recordDiameter)
                        try require(difference < 0.003, "fresh process changed \(captureName): \(difference)")
                        print("FRESH PROCESS \(captureName): mean RGB difference \(difference)"); fflush(stdout)
                    }
                }
            }
        }
        try await stopped("visual matrix settled")
        let accessibleTrack = previewTracks[1]
        player.applyPreviewEvents([.queueChanged(PlaybackQueue(generation: 999, previous: [],
            current: QueueEntry(id: "accessibility", uri: accessibleTrack.uri, target: nil, track: accessibleTrack, metadataFailed: false), next: [])),
            .trackChanged(accessibleTrack), .paused(positionMs: 0)])
        try await settle(850)
        settings.increasedContrast = true
        try await settle(300)
        try require(MonolithPressingProbe.contrast == .increased, "native high-contrast appearance must reach the record environment")
        try await capture(panel, output: output, name: "accessibility-increased-contrast")
        settings.increasedContrast = false
        settings.reduceMotion = true
        try await settle(300)
        try await capture(panel, output: output, name: "accessibility-reduce-motion")
        try await stopped("accessibility Reduce Motion")
        settings.reduceTransparency = true
        try await settle(850)
        try await capture(panel, output: output, name: "accessibility-reduce-transparency")
        try await stopped("accessibility Reduce Transparency")
        settings.reduceTransparency = false
        settings.reduceMotion = false
        try await settle(850)
        print("VISUAL MATRIX: colourful/warm attention/greyscale/missing, 118/182pt, light/dark PASS"); fflush(stdout)
    }

    private static func verifyPressings(player: PlayerModel, environment: AppEnvironment, settings: PressingProbeSettings,
                                       panel: StatusPanel, controller: PlayerWindowController, output: URL) async throws {
        let gate = PressingPaletteGate()
        PressingArtworkProtocol.data = environment.artworkStore.images[previewArtworkURL(1)]!.tiffRepresentation!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PressingArtworkProtocol.self]
        settings.artworkStore = ArtworkStore(session: URLSession(configuration: configuration), paletteExtractor: { await gate.extract($0) })
        let aURL = URL(string: "https://pressing.invalid/a")!
        let bURL = URL(string: "https://pressing.invalid/b")!
        let aPalette = ArtworkPalette.marble(.init(red: 0.05, green: 0.7, blue: 0.85), .init(red: 0.7, green: 0.12, blue: 0.65), .init(red: 0.1, green: 0.2, blue: 0.45))
        let bPalette = ArtworkPalette.marble(.init(red: 0.9, green: 0.35, blue: 0.05), .init(red: 0.75, green: 0.08, blue: 0.04), .init(red: 0.4, green: 0.2, blue: 0.08))
        var generation: UInt64 = 20
        func select(_ uri: String, artwork: URL?, occurrence: String = UUID().uuidString) {
            generation += 1
            let track = Track(uri: SpotifyURI(uri)!, title: "Pressing fixture", artists: [], albumTitle: nil,
                              artwork: artwork.map(Artwork.init(url:)), durationMs: 240_000)
            player.applyPreviewEvents([.queueChanged(PlaybackQueue(generation: generation, previous: [],
                current: QueueEntry(id: occurrence, uri: track.uri, target: nil, track: track, metadataFailed: false), next: [])),
                .trackChanged(track), .paused(positionMs: 0)])
        }
        func expect(_ uri: String, _ palette: ArtworkPalette) throws {
            let current = MonolithPressingProbe.samples.last!
            try require(current.0 == PressingSeed.offset(uri) && current.1 == palette, "seed and palette must publish together for \(uri)")
        }
        select("spotify:track:pressingA", artwork: aURL)
        try await wait(gate, count: 1); await gate.release(1, aPalette)
        try await settle(800)
        try expect("spotify:track:pressingA", aPalette)
        let aImage = try await capture(panel, output: output, name: "identity-a")
        select("spotify:track:pressingB", artwork: bURL)
        try await wait(gate, count: 2); try await settle(200)
        try expect("spotify:track:pressingA", aPalette)
        let held = try await capture(panel, output: output, name: "identity-b-pending")
        try require(annulusDifference(aImage, held, center: controller.layout.recordCenter, diameter: controller.layout.recordDiameter) < 0.003, "pending B must keep A's visible pressing")
        select("spotify:track:pressingC", artwork: aURL)
        try await settle(800)
        try expect("spotify:track:pressingC", aPalette)
        await gate.release(2, bPalette); try await settle(100)
        try expect("spotify:track:pressingC", aPalette)
        let cImage = try await capture(panel, output: output, name: "identity-c")
        try require(annulusDifference(aImage, cImage, center: controller.layout.recordCenter, diameter: controller.layout.recordDiameter) > 0.02, "shared cover must have different URI swirls")
        select("spotify:track:pressingC", artwork: aURL, occurrence: "repeat")
        try await settle(800)
        let repeated = try await capture(panel, output: output, name: "identity-c-repeat")
        try require(annulusDifference(cImage, repeated, center: controller.layout.recordCenter, diameter: controller.layout.recordDiameter) < 0.003, "occurrence must not change pressing")
        select("spotify:track:pressingB", artwork: bURL)
        try await settle(200)
        try await capture(panel, output: output, name: "dissolve-b-200ms")
        try require(MonolithPressingProbe.layers >= 2, "dissolve must retain outgoing layer")
        select("spotify:track:pressingA", artwork: aURL)
        try await settle(200)
        let interrupted = try await capture(panel, output: output, name: "dissolve-interrupted-200ms")
        try require(saturatedFraction(interrupted, center: controller.layout.recordCenter, diameter: controller.layout.recordDiameter) > 0.2, "interrupted dissolve must not flash neutral")
        try await settle(800)
        try require(MonolithPressingProbe.layers == 1, "settled dissolve must release outgoing layers")
        try await stopped("pressing dissolve settled")

        select("spotify:track:late", artwork: nil); try await settle(800)
        try expect("spotify:track:late", .neutral)
        select("spotify:track:late", artwork: URL(string: "https://pressing.invalid/late")!)
        try await wait(gate, count: 3)
        try expect("spotify:track:late", .neutral)
        await gate.release(3, bPalette); try await settle(800)
        try expect("spotify:track:late", bPalette)
        select("spotify:track:failed", artwork: URL(string: "https://pressing.invalid/failure")!)
        try await wait(gate, count: 4); await gate.release(4, nil); try await settle(800)
        try expect("spotify:track:failed", .neutral)
        select("spotify:track:httpFailure", artwork: URL(string: "https://pressing.invalid/http-failure")!)
        try await settle(800); try expect("spotify:track:httpFailure", .neutral)
        player.applyPreviewEvents([.activeDeviceChanged(isActive: false), .remotePlayback(RemotePlayback(deviceName: "Fixture", trackURI: SpotifyURI("spotify:track:mirrorOnly")!,
            track: nil, isPlaying: true, positionMs: 0, durationMs: 240_000))])
        try await settle(800); try expect("spotify:track:mirrorOnly", .neutral)
        try await stopped("mirror without metadata")
        let metadataURI = SpotifyURI("spotify:track:metadataLate")!
        player.applyPreviewEvents([.queueChanged(PlaybackQueue(generation: 99, previous: [],
            current: QueueEntry(id: "metadata-pending", uri: metadataURI, target: nil, track: nil, metadataFailed: false), next: [])),
            .activeDeviceChanged(isActive: true)])
        try await settle(250)
        try expect(metadataURI.rawValue, .neutral)
        player.applyPreviewEvents([.trackChanged(Track(uri: metadataURI, title: "Late metadata", artists: [], albumTitle: nil,
                                                      artwork: Artwork(url: aURL), durationMs: 240_000))])
        try await settle(800); try expect(metadataURI.rawValue, aPalette)
        settings.reduceMotion = true
        select("spotify:track:pressingA", artwork: aURL); try await settle(250)
        try expect("spotify:track:pressingA", aPalette)
        try require(MonolithPressingProbe.layers == 1, "Reduce Motion dissolve must finish in 0.16s")
        try await stopped("Reduce Motion pressing")
        settings.reduceMotion = false
        print("IDENTITY: repeat/shared art, delayed and stale palettes, interrupted dissolve, late URL, failures, mirror URI, Reduce Motion PASS"); fflush(stdout)
    }

    private static func wait(_ gate: PressingPaletteGate, count: Int) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while await gate.count < count {
            try require(ProcessInfo.processInfo.systemUptime < deadline, "palette fixture did not start")
            try await settle(10)
        }
    }

    private static func verifyMotor(player: PlayerModel, presentation: PlayerPresentation,
                                    settings: PressingProbeSettings, panel: StatusPanel) async throws {
        func play() async throws { player.applyPreviewEvents([.playing(positionMs: 64_000)]); try await settle(700) }
        func pause() { player.applyPreviewEvents([.paused(positionMs: 64_000)]) }
        try await play()
        try await moving("playing")
        pause()
        try await settle(40)
        try await moving("pause coast", milliseconds: 180)
        try await settle(650)
        try await stopped("paused")
        try await play()
        pause(); try await settle(150)
        player.applyPreviewEvents([.playing(positionMs: 64_000)])
        try await settle(600)
        try await moving("resume survives old deadline")
        pause(); try await settle(200)
        player.applyPreviewEvents([.playing(positionMs: 64_000)])
        try await settle(100); pause(); try await settle(330)
        try await moving("new brake survives old deadline", milliseconds: 100)
        try await settle(650); try await stopped("replacement brake settled")
        player.applyPreviewEvents([.playing(positionMs: 64_000)])
        try await settle(120)
        settings.reduceMotion = true
        try await settle(90); try await stopped("Reduce Motion during spin-up")
        settings.reduceMotion = false

        try await play()
        let scrubPointer = try recordPointer(panel.contentView!)
        let right = scrubPointer.convert(CGPoint(x: scrubPointer.bounds.midX + 35, y: scrubPointer.bounds.midY), to: nil)
        let bottom = scrubPointer.convert(CGPoint(x: scrubPointer.bounds.midX, y: scrubPointer.bounds.midY + 35), to: nil)
        let seeksBefore = MonolithMotorProbe.seeks.count
        scrubPointer.mouseDown(with: mouse(.leftMouseDown, point: right, panel: panel))
        let heldAngle = MonolithMotorProbe.samples.last!.1
        try require(MonolithMotorProbe.samples.last!.2 == 0, "press must zero angular speed")
        scrubPointer.mouseDragged(with: mouse(.leftMouseDragged, point: bottom, panel: panel))
        scrubPointer.mouseUp(with: mouse(.leftMouseUp, point: bottom, panel: panel))
        let released = MonolithMotorProbe.samples.last!
        try require(abs(released.1 - heldAngle - .pi / 2) < 1e-8 && released.2 == 0, "scrub release must preserve the held angle and restart from rest")
        try await settle(300)
        try require(MonolithMotorProbe.seeks.count == seeksBefore + 1, "scrub must issue exactly one seek")
        try await moving("scrub release")
        print("SCRUB: continuous angle, zero release speed, one seek"); fflush(stdout)

        for duringBrake in [false, true] {
            try await play()
            if duringBrake { pause(); try await settle(100) }
            presentation.isVisible = false
            try await settle(90); try await stopped("hidden \(duringBrake)")
            presentation.isVisible = true; presentation.sendAttention(.keyboardFocus(true))
            try await play()
            if duringBrake { pause(); try await settle(100) }
            settings.reduceMotion = true
            try await settle(90); try await stopped("Reduce Motion \(duringBrake)")
            settings.reduceMotion = false
            try await play()
            if duringBrake { pause(); try await settle(100) }
            let pointer = try recordPointer(panel.contentView!)
            let point = pointer.convert(CGPoint(x: pointer.bounds.midX + 35, y: pointer.bounds.midY), to: nil)
            pointer.mouseDown(with: mouse(.leftMouseDown, point: point, panel: panel))
            try await settle(90); try await stopped("pointer press \(duringBrake)")
            pointer.mouseUp(with: mouse(.leftMouseUp, point: point, panel: panel))
            if !duringBrake { try await moving("pointer release spins up") }
            try await play()
            if duringBrake { pause(); try await settle(100) }
            player.applyPreviewEvents([.loading])
            try await settle(90); try await stopped("loading \(duringBrake)")
        }
        for event in [PlaybackEvent.endOfTrack, .failed(.networkUnavailable)] {
            try await play(); player.applyPreviewEvents([event])
            try await moving("end/error coast", milliseconds: 180)
            try await settle(650); try await stopped("end/error settled")
        }
        try await play()
        player.applyPreviewEvents([.activeDeviceChanged(isActive: false)])
        try await settle(40)
        try await moving("device loss coast", milliseconds: 180)
        try await settle(650); try await stopped("device loss settled")
        try require(RecordMotorRequest.resolve(phase: .buffering, ready: true, active: true, visible: true, reduced: false, pressed: false) == .snap,
                    "buffering policy must snap")
        try require(RecordMotorRequest.resolve(phase: .idle, ready: true, active: true, visible: true, reduced: false, pressed: false) == .snap,
                    "local idle policy must snap")
        for duringBrake in [false, true] {
            try await play()
            if duringBrake { pause(); try await settle(100) }
            settings.mounted = false
            try await settle(90); try await stopped("disappeared \(duringBrake)")
            settings.mounted = true
            try await settle(700)
        }
        player.applyPreviewEvents([.playing(positionMs: 64_000)])
        try await settle(700)
        try await moving("remounted")
        player.applyPreviewEvents([.sessionLost(.legacy)])
        try await settle(90); try await stopped("recovery overrides error brake")
        player.detachEngine()
        try await stopped("engine detached")
    }

    private static func moving(_ name: String, milliseconds: Int = 240) async throws {
        let ticks = MonolithAmbientProbe.ticks
        try await settle(milliseconds)
        let delta = MonolithAmbientProbe.ticks - ticks
        try require(delta >= 2, "\(name) must animate; got \(delta) ticks")
        print("MOTOR \(name): \(delta) ticks"); fflush(stdout)
    }

    private static func verifyEngineStops() async throws {
        for recovering in [false, true] {
            for duringBrake in [false, true] {
                let environment = makePreviewEnvironment(.playing)
                let player = environment.player!
                let presentation = PlayerPresentation()
                presentation.isVisible = true
                let controller = PlayerWindowController(previewMode: .compact)
                let settings = PressingProbeSettings()
                let panel = StatusPanel(content: PressingProbeScene(environment: environment, presentation: presentation,
                                                                   controller: controller, settings: settings))
                panel.setFrame(CGRect(x: 300, y: 300, width: 264, height: 264), display: true)
                panel.makeKeyAndOrderFront(nil)
                try await settle(700)
                try await moving("detachment control")
                if duringBrake { player.applyPreviewEvents([.paused(positionMs: 0)]); try await settle(100) }
                if recovering { player.applyPreviewEvents([.sessionLost(.legacy)]) }
                else { player.detachEngine() }
                try await settle(90)
                try require(MonolithMotorProbe.samples.last!.0 == .snap && MonolithMotorProbe.samples.last!.2 == 0,
                            "detachment and recovery must snap during drive and brake")
                try await stopped("\(recovering ? "recovery" : "detachment") \(duringBrake)")
                player.stop(); panel.orderOut(nil)
            }
        }
    }

    private static func stopped(_ name: String) async throws {
        for _ in 0..<2 {
            let ticks = MonolithAmbientProbe.ticks
            try await settle(180)
            let delta = MonolithAmbientProbe.ticks - ticks
            try require(delta == 0, "\(name) must settle; got \(delta) ticks")
        }
        print("MOTOR \(name): two zero-tick windows"); fflush(stdout)
    }
    #endif

    private static func recordPointer(_ view: NSView) throws -> RecordPointerRegion.PointerView {
        if let pointer = view as? RecordPointerRegion.PointerView { return pointer }
        for child in view.subviews { if let pointer = try? recordPointer(child) { return pointer } }
        throw NSError(domain: "record pointer unavailable", code: 1)
    }
    private static func mouse(_ type: NSEvent.EventType, point: CGPoint, panel: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    }
    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: message, code: 1) }
    }
    private static func settle(_ milliseconds: Int) async throws { try await Task.sleep(for: .milliseconds(milliseconds)) }
    @discardableResult private static func capture(_ panel: NSWindow, output: URL, name: String) async throws -> CGImage {
        let content = try await SCShareableContent.currentProcess
        guard let window = content.windows.first(where: { $0.windowID == panel.windowNumber }) else {
            throw NSError(domain: "fixture window unavailable", code: 1)
        }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(panel.frame.width * 2)
        configuration.height = Int(panel.frame.height * 2)
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration)
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
        print("CAPTURE \(name)"); fflush(stdout)
        return image
    }
    private static func saturatedFraction(_ image: CGImage, center: CGPoint, diameter: CGFloat) -> Double {
        let bitmap = NSBitmapImageRep(cgImage: image)
        let radius = diameter
        var coloured = 0
        var total = 0
        for y in stride(from: Int(center.y * 2 - radius), to: Int(center.y * 2 + radius), by: 3) {
            for x in stride(from: Int(center.x * 2 - radius), to: Int(center.x * 2 + radius), by: 3) {
                let distance = hypot(Double(x) - center.x * 2, Double(y) - center.y * 2)
                guard distance > radius * 0.55, distance < radius * 0.85,
                      let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                total += 1
                if max(color.redComponent, color.greenComponent, color.blueComponent) - min(color.redComponent, color.greenComponent, color.blueComponent) > 0.13 { coloured += 1 }
            }
        }
        return Double(coloured) / Double(max(1, total))
    }
    private static func annulusDifference(_ first: CGImage, _ second: CGImage, center: CGPoint, diameter: CGFloat) -> Double {
        let a = NSBitmapImageRep(cgImage: first), b = NSBitmapImageRep(cgImage: second)
        var difference = 0.0, count = 0.0
        for y in stride(from: Int(center.y * 2 - diameter), to: Int(center.y * 2 + diameter), by: 4) {
            for x in stride(from: Int(center.x * 2 - diameter), to: Int(center.x * 2 + diameter), by: 4) {
                let distance = hypot(Double(x) - center.x * 2, Double(y) - center.y * 2)
                guard distance > diameter * 0.55, distance < diameter * 0.85,
                      let ac = a.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), let bc = b.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                difference += abs(ac.redComponent - bc.redComponent) + abs(ac.greenComponent - bc.greenComponent) + abs(ac.blueComponent - bc.blueComponent)
                count += 3
            }
        }
        return difference / max(1, count)
    }
}
