import SwiftUI
import ScreenCaptureKit
import BopifyPlayback
import BopifyDomain

// Production views against a stub engine; never starts Spotify.
@main struct MonolithMirrorProbe {
    private actor Library: LibraryService {
        func savedState(for uri: SpotifyURI) async throws -> Bool { false }
        func save(_ uri: SpotifyURI) async throws {}
        func remove(_ uri: SpotifyURI) async throws {}
    }
    static var output: URL { URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true) }
    @MainActor static var failures: [String] = []
    @MainActor static func check(_ value: Bool, _ message: String) {
        print("\(value ? "PASS" : "FAIL"): \(message)")
        if !value { failures.append(message) }
        fflush(nil)
    }
    @MainActor static func settle() async { try? await Task.sleep(for: .milliseconds(900)) }
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        Task { @MainActor in
            let engine = StubPlaybackEngine()
            let player = PlayerModel(engine: engine)
            player.start()
            let environment = AppEnvironment(previewPlayer: player, favoriteService: Library())
            let status = StatusItemController(content: MiniPlayerView(environment: environment), environment: environment)
            let panel = app.windows.compactMap { $0 as? StatusPanel }.first!
            // The record is found by role, because the sleeve's title text carries the same label.
            @MainActor func element(_ label: String, role: String? = nil) -> NSObject? {
                accessibilityTree(panel.contentView!).first {
                    attribute($0, "accessibilityLabel") as? String == label
                        && (role == nil || attribute($0, "accessibilityRole") as? String == role)
                }
            }
            @MainActor func enabled(_ label: String) -> Bool? { element(label).map { booleanAction($0, "isAccessibilityEnabled") } }
            @MainActor func recordStatus(_ title: String) -> String? { element(title, role: "AXButton").flatMap { attribute($0, "accessibilityValue") as? String } }
            @MainActor func pressPlay() { _ = element("Play").map { booleanAction($0, "accessibilityPerformPress") } }
            status.perform(NSSelectorFromString("handleClick"))
            await settle()
            // Holds the reveal as VoiceOver focus does: the probe checks what the controls show, and window focus is outside its control.
            environment.presentation.sendAttention(.accessibilityFocus(true))

            let phone = Track(uri: SpotifyURI("spotify:track:remote")!, title: "Remote track", artists: [ArtistSummary(name: "Phone Artist")],
                              albumTitle: nil, artwork: nil, durationMs: 200_000)
            func mirror(playing: Bool, at position: Int64) -> PlaybackEvent {
                .remotePlayback(RemotePlayback(deviceName: "iPhone", trackURI: phone.uri, track: phone,
                                               isPlaying: playing, positionMs: position, durationMs: 200_000))
            }
            engine.emit(.startupResolved(.remote(deviceName: "iPhone")))
            engine.emit(mirror(playing: true, at: 1000))
            await settle()
            check(environment.isListening && environment.presentation.mode == .expanded && panel.frame.size == CGSize(width: 484, height: 264),
                  "a mirrored track opens the record and sleeve at listening geometry")
            check(recordStatus("Remote track") == "Playing on iPhone", "the record names the mirrored track and its device")
            check(enabled("Play") == true, "Play is enabled while mirroring")
            for label in ["Previous", "Next", "Shuffle", "Repeat", "Up Next", "Mute"] {
                check(enabled(label) == false, "\(label) is disabled while mirroring")
            }
            check(element("Spotify favorite") == nil, "the favourite is hidden while mirroring with no track of Bopify's own")
            let playing = await capture(panel, "mirror-playing")
            pressPlay()
            await settle()
            check(engine.recordedCommands == ["playHere"], "Play on the mirror asks the engine to play here")

            engine.emit(mirror(playing: false, at: 5000))
            await settle()
            check(recordStatus("Remote track") == "Paused on iPhone", "a paused device is named as paused")
            let paused = await capture(panel, "mirror-paused")

            // At launch Bopify has no track of its own, so the stopped device's track stays.
            engine.emit(.remotePlayback(nil))
            await settle()
            check(environment.isListening && recordStatus("Remote track") == "Not playing",
                  "a stopped device's last track stays on the record and says nothing plays")
            check(enabled("Play") == true && enabled("Up Next") == false, "the stale mirror offers only Play")
            let staleMirror = await capture(panel, "stale-mirror")
            pressPlay()
            await settle()
            check(engine.recordedCommands == ["playHere", "playHere"], "Play on the stale mirror asks the engine to play here")

            let stale = Track(uri: SpotifyURI("spotify:track:stale")!, title: "Stale track", artists: [], albumTitle: nil, artwork: nil, durationMs: 240_000)
            engine.emit(.trackChanged(stale))
            engine.emit(.paused(positionMs: 1545))
            await settle()
            check(recordStatus("Stale track") == "Paused" && player.state.mirror == nil, "becoming active drops the mirror")
            let baseline = await capture(panel, "active-paused")
            // A takeover by a device that never reported a track leaves Bopify's own track.
            engine.emit(.activeDeviceChanged(isActive: false))
            engine.emit(.remotePlayback(nil))
            await settle()
            check(recordStatus("Stale track") == "Not playing", "with nothing mirrored, Bopify's own last track stays and says so")
            check(enabled("Play") == true, "Play is enabled in the stale state")
            let idle = await capture(panel, "stale-own")
            pressPlay()
            await settle()
            check(engine.recordedCommands == ["playHere", "playHere", "playHere"], "Play in the stale state asks the engine to play here")

            engine.emit(.failed(.networkUnavailable))
            await settle()
            let error = await capture(panel, "error")
            if let playing, let paused, let staleMirror, let baseline, let idle, let error {
                let limit = orangePixels(baseline) + 80
                check(orangePixels(error) > limit, "the rim detector sees an error rim")
                check([playing, paused, staleMirror, idle].allSatisfy { orangePixels($0) <= limit },
                      "neither the mirror nor the stale state draws the attention rim")
            }
            player.stop()
            print(failures.isEmpty ? "MONOLITH MIRROR PASS" : "MONOLITH MIRROR FAIL")
            if !failures.isEmpty { exit(1) }
            withExtendedLifetime(status) { app.terminate(nil) }
        }
        app.run()
    }

    @MainActor static func capture(_ panel: StatusPanel, _ name: String) async -> CGImage? {
        do {
            let content = try await SCShareableContent.currentProcess
            guard let window = content.windows.first(where: { $0.windowID == panel.windowNumber }) else {
                check(false, "capture \(name): window missing"); return nil
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
        } catch {
            check(false, "capture \(name): \(error)")
            return nil
        }
    }
    /// The same orange test as MonolithVisualProbe's rim check, over the whole window.
    @MainActor static func orangePixels(_ image: CGImage) -> Int {
        let bitmap = NSBitmapImageRep(cgImage: image)
        var count = 0
        for y in 0..<image.height {
            for x in 0..<image.width {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.alphaComponent > 0.2 && color.redComponent > 0.5 && color.greenComponent > 0.15
                    && color.redComponent > color.greenComponent * 1.15 && color.greenComponent > color.blueComponent * 1.3 { count += 1 }
            }
        }
        return count
    }
    @MainActor static func attribute(_ value: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        guard value.responds(to: selector) else { return nil }
        return value.perform(selector)?.takeUnretainedValue()
    }
    @MainActor static func booleanAction(_ value: NSObject, _ name: String) -> Bool {
        let selector = NSSelectorFromString(name)
        precondition(value.responds(to: selector), "missing accessibility method \(name)")
        typealias Action = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(value.method(for: selector), to: Action.self)(value, selector)
    }
    @MainActor static func accessibilityTree(_ value: Any) -> [NSObject] {
        guard let element = value as? NSObject else { return [] }
        return [element] + ((attribute(element, "accessibilityChildren") as? [Any]) ?? []).flatMap { accessibilityTree($0) }
    }
}
