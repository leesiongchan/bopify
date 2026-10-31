import AppKit
import SwiftUI
import Observation
import Testing
import BopifyDomain
import BopifyLibrary
import BopifyPlayback

@MainActor @Suite("Record continuity", .serialized)
struct RecordContinuityTests {
    @Test(.enabled("Requires screen capture or host capture helper") { @MainActor in VinylRenderingFixture.canCapture })
    func globalStyleUpdatesWithoutChangingLabelOrPlayback() async throws {
        let track = previewTracks[0]
        let store = ArtworkStore(previewImages: [track.artwork!.url: artwork(.red)])
        _ = await store.loadPalette(track.artwork!.url)
        let engine = LiveLyricTestEngine()
        let player = PlayerModel(engine: engine)
        player.applyPreviewEvents([.trackChanged(track), .paused(positionMs: 0)])
        player.start()
        defer { player.stop() }
        let service = ContinuityLibrary(track: previewTracks[1])
        let environment = AppEnvironment(previewPlayer: player, favoriteService: service,
            savedTracksService: service, artworkStore: store)
        environment.presentation.sendAttention(.visibility(true))
        environment.presentation.sendAttention(.keyboardFocus(true))
        let suite = "bopify-style-player-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = PlayerWindowController(defaults: defaults)
        let panel = StatusPanel(content: RecordPlayerView(player: player, artworkStore: store,
            presentation: environment.presentation, windowController: controller)
            .environment(environment).defaultAppStorage(defaults))
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        controller.attach(to: panel)
        controller.apply(mode: .expanded, reduceMotion: true, visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        panel.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(800))
        let beforeLabel = try samplePhoto(panel, layout: controller.layout)
        let before = try await VinylRenderingFixture.capture(panel,
            to: VinylRenderingFixture.directory.appendingPathComponent("player-original.png"))
        defaults.set("carnival", forKey: VinylDesign.preferenceKey)
        try await Task.sleep(for: .milliseconds(400))
        let afterLabel = try samplePhoto(panel, layout: controller.layout)
        let after = try await VinylRenderingFixture.capture(panel,
            to: VinylRenderingFixture.directory.appendingPathComponent("player-carnival.png"))
        #expect(abs(beforeLabel.redComponent - afterLabel.redComponent) < 0.01)
        #expect(abs(beforeLabel.blueComponent - afterLabel.blueComponent) < 0.01)
        #expect(player.state.currentTrack?.uri == track.uri)
        #expect(engine.loadRequests.isEmpty)
        let host = try #require(panel.contentView)
        let scale = CGFloat(before.pixelsWide) / host.bounds.width
        let layout = controller.layout
        let rect = CGRect(x: layout.recordCenter.x - layout.recordDiameter / 2,
            y: layout.recordCenter.y - layout.recordDiameter / 2,
            width: layout.recordDiameter, height: layout.recordDiameter)
            .applying(CGAffineTransform(scaleX: scale, y: scale))
        let oldRecord = NSBitmapImageRep(cgImage: try #require(before.cgImage?.cropping(to: rect)))
        let newRecord = NSBitmapImageRep(cgImage: try #require(after.cgImage?.cropping(to: rect)))
        #expect(VinylRenderingFixture.differingAnnulusFraction(oldRecord, newRecord) > 0.10)
    }

    @Test func collapsingDuringArrivalKeepsTheOldPhotoUnderneath() async throws {
        let old = previewTracks[1]
        let next = previewTracks[0]
        let store = ArtworkStore(previewImages: [old.artwork!.url: artwork(.red), next.artwork!.url: artwork(.blue)])
        _ = await store.loadPalette(old.artwork!.url)
        _ = await store.loadPalette(next.artwork!.url)
        let engine = LiveLyricTestEngine()
        let player = PlayerModel(engine: engine)
        player.applyPreviewEvents([.trackChanged(old), .paused(positionMs: 0)])
        player.start()
        defer { player.stop() }
        let service = ContinuityLibrary(track: next)
        let environment = AppEnvironment(previewPlayer: player, favoriteService: service,
                                         savedTracksService: service, artworkStore: store)
        let presentation = environment.presentation
        presentation.sendAttention(.visibility(true))
        presentation.sendAttention(.keyboardFocus(true))
        let suite = "\(NSTemporaryDirectory())bopify-continuity-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("liked", forKey: "library.tab")
        let controller = PlayerWindowController(defaults: defaults)
        let panel = StatusPanel(content: RecordPlayerView(player: player, artworkStore: store,
            presentation: presentation, windowController: controller).environment(environment).defaultAppStorage(defaults))
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        controller.attach(to: panel)
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        controller.apply(mode: .expanded, reduceMotion: true, visibleFrame: screen)
        panel.makeKeyAndOrderFront(nil)
        try await waitUntil { findInput(panel.contentView)?.input != nil && !environment.likedSongs.tracks.isEmpty }
        try await Task.sleep(for: .milliseconds(200))
        let initial = try samplePhoto(panel, layout: controller.layout)
        #expect(initial.redComponent > 0.8)
        let input = try #require(findInput(panel.contentView))
        let point = input.convert(CGPoint(x: input.bounds.midX, y: input.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            panel.sendEvent(try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)))
        }
        try await waitUntil { engine.loadRequests.count == 1 }
        engine.emit(.trackChanged(next))
        engine.emit(.paused(positionMs: 0))
        try await waitUntil { player.state.currentTrack?.uri == next.uri }
        presentation.sendAttention(.keyboardFocus(false))
        presentation.sendAttention(.pointer(false))
        try await waitUntil { presentation.mode == .compact }
        controller.apply(mode: .compact, reduceMotion: true, visibleFrame: screen)
        try await Task.sleep(for: .milliseconds(100))
        let underneath = try samplePhoto(panel, layout: controller.layout)
        #expect(underneath.redComponent > 0.8 && underneath.blueComponent < 0.2,
                "Focus collapse must retain the old photo until the incoming cover reaches the spindle")
        try await Task.sleep(for: .milliseconds(1500))
        let arrived = try samplePhoto(panel, layout: controller.layout)
        #expect(arrived.blueComponent > 0.8 && arrived.redComponent < 0.2)
        presentation.sendAttention(.keyboardFocus(true))
        controller.apply(mode: .expanded, reduceMotion: false, visibleFrame: screen)
        try await Task.sleep(for: .milliseconds(700))
        let expanded = try samplePhoto(panel, layout: controller.layout)
        #expect(expanded.blueComponent > 0.8 && expanded.redComponent < 0.2)
    }

    @Test func labelKeepsItsArrivalPhaseAtEveryRecordSizeAndMotorPhase() async throws {
        let image = NSImage(size: NSSize(width: 160, height: 160), flipped: false) { rect in
            NSColor.red.setFill(); rect.fill()
            NSColor.blue.setFill(); CGRect(x: 80, y: 0, width: 80, height: 160).fill()
            return true
        }
        for phase in [-Double.pi + 0.01, Double.pi - 0.01, 9 * Double.pi - 0.01] {
            for diameter in [182.0, 150.0, 118.0, 182.0] {
                let host = NSHostingView(rootView: VinylRecordView(image: Image(nsImage: image), occurrenceID: "arrival",
                    direction: .fade, diameter: diameter, isMoving: false, isVisible: true, rotation: RecordRotation(),
                    artworkRotationOffset: -phase, rotationOverride: phase + 0.25, labelRatio: 76.0 / 182)
                    .frame(width: 240, height: 240))
                let window = NSWindow(contentRect: CGRect(x: 300, y: 300, width: 240, height: 240),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                window.orderFrontRegardless()
                try await Task.sleep(for: .milliseconds(40))
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                for side in [-1.0, 1.0] {
                    let x = (120 + side * diameter * 0.16) * CGFloat(bitmap.pixelsWide) / 240
                    let color = try #require(bitmap.colorAt(x: Int(x), y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
                    #expect(side < 0 ? color.redComponent > 0.8 : color.blueComponent > 0.8)
                }
                window.close()
            }
        }
    }

    @Test func artworkScalesWithTheDiscThroughoutFocusAnimation() async throws {
        let fixture = RecordResizeFixture()
        let host = NSHostingView(rootView: RecordResizeScene(fixture: fixture, image: Image(nsImage: artwork(.red))))
        let window = NSWindow(contentRect: CGRect(x: 300, y: 300, width: 240, height: 240),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(100))
        for target in [118.0, 182.0] {
            fixture.diameter = target
            for _ in 0..<8 {
                try await Task.sleep(for: .milliseconds(80))
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let center = bitmap.pixelsWide / 2
                var photoRadius = 0
                var discRadius = 0
                for x in (center + 4)..<bitmap.pixelsWide {
                    let color = try #require(bitmap.colorAt(x: x, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
                    if color.redComponent > 0.8 && color.blueComponent < 0.2 { photoRadius = x - center }
                    if color.alphaComponent > 0.95 { discRadius = x - center }
                }
                #expect(photoRadius > 18)
                #expect(abs(Double(photoRadius) / Double(discRadius) - 76.0 / 182) < 0.04,
                        "The label and disc must use the same interpolated size during focus changes")
            }
        }
    }

    private func artwork(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 160, height: 160), flipped: false) { rect in
            color.setFill(); rect.fill(); return true
        }
    }

    private func samplePhoto(_ panel: NSWindow, layout: RecordLayout) throws -> NSColor {
        let host = try #require(panel.contentView)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let point = CGPoint(x: layout.recordCenter.x + layout.recordDiameter * 0.1, y: layout.recordCenter.y)
        return try #require(bitmap.colorAt(x: Int(point.x * CGFloat(bitmap.pixelsWide) / host.bounds.width),
            y: Int(point.y * CGFloat(bitmap.pixelsHigh) / host.bounds.height))?.usingColorSpace(.deviceRGB))
    }

    private func findInput(_ view: NSView?) -> CoverFlowInput.InputView? {
        if let input = view as? CoverFlowInput.InputView { return input }
        return view?.subviews.lazy.compactMap { findInput($0) }.first
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }
}

@MainActor @Observable private final class RecordResizeFixture {
    var diameter = 182.0
}

private struct RecordResizeScene: View {
    let fixture: RecordResizeFixture
    let image: Image
    var body: some View {
        VinylRecordView(image: image, occurrenceID: "same-cover", direction: .fade, diameter: fixture.diameter,
            isMoving: false, isVisible: true, rotation: RecordRotation(), labelRatio: 76.0 / 182)
            .animation(.spring(duration: 0.5, bounce: 0.18), value: fixture.diameter)
            .frame(width: 240, height: 240)
    }
}

private nonisolated struct ContinuityLibrary: LibraryService, SavedTracksService {
    let track: Track
    func savedState(for uri: SpotifyURI) async throws -> Bool { false }
    func save(_ uri: SpotifyURI) async throws {}
    func remove(_ uri: SpotifyURI) async throws {}
    func savedTracks(offset: Int, limit: Int) async throws -> SavedTracksPage {
        SavedTracksPage(tracks: [track], nextOffset: nil)
    }
}
