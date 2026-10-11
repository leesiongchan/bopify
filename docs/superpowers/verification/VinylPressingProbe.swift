import SwiftUI
import ScreenCaptureKit
import Observation
import BopifyDomain
import BopifyPlayback

@Observable private final class PressingProbeSettings {
    var reduceMotion = false
    var mounted = true
}

private struct PressingProbeScene: View {
    let environment: AppEnvironment
    let presentation: PlayerPresentation
    let controller: PlayerWindowController
    let settings: PressingProbeSettings
    var body: some View {
        if settings.mounted {
            RecordPlayerView(player: environment.player!, artworkStore: environment.artworkStore,
                             presentation: presentation, windowController: controller, reduceMotionOverride: settings.reduceMotion)
                .environment(environment)
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
                try await capture(panel, output: output, name: "\(ProcessInfo.processInfo.environment["VINYL_PROBE_BASELINE"] == "1" ? "baseline" : "pressing")-\(Int(controller.layout.recordDiameter))-\(dark ? "dark" : "light")")
            }
        }
        if ProcessInfo.processInfo.environment["VINYL_PROBE_BASELINE"] == "1" { return }
        #if MONOLITH_MEASURE
        try await verifyMotor(player: player, presentation: presentation, settings: settings, panel: panel)
        #endif
    }

    #if MONOLITH_MEASURE
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
    private static func capture(_ panel: NSWindow, output: URL, name: String) async throws {
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
    }
}
