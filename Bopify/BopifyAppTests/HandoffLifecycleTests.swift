import AppKit
import SwiftUI
import Testing
import BopifyDomain
import BopifyLibrary
import BopifyPlayback

@MainActor @Suite("Handoff lifecycle", .serialized)
struct HandoffLifecycleTests {
    @Test func replacementKeepsTheRevealedRecordInsteadOfReturningToTheFirstSong() async throws {
        let f = try await HandoffAuditFixture.make()
        defer { f.close() }
        #expect(try f.sample("A-initial").redComponent > 0.8)
        let firstLaunch = Date()
        try f.clickCenter()
        try await f.wait { f.engine.loadRequests.count == 1 }
        f.engine.emit(.trackChanged(f.b))
        f.engine.emit(.paused(positionMs: 0))
        // Prepare C while B is arriving, then wait for B's actual rendered pixels.
        f.environment.likedSongs.select(f.c.uri)
        try await f.settleShelf()
        try await f.wait { Date().timeIntervalSince(firstLaunch) >= CoverFlowLaunch.duration * 0.65 }
        try await f.wait { (try? f.sample().greenComponent) ?? 0 > 0.85 }
        let before = try f.sample("B-visible-before-C")
        #expect(before.greenComponent > 0.85 && before.redComponent < 0.15)
        let secondLaunch = Date()
        #expect(secondLaunch.timeIntervalSince(firstLaunch) < CoverFlowLaunch.duration,
                "The second click must occur before B's handoff completes")
        try f.clickCenter()
        try await f.wait { f.engine.loadRequests.count == 2 }
        #expect(f.engine.loadRequests.last?.contextURI == f.c.uri)
        f.engine.emit(.loading)
        try await f.wait { f.player.state.phase == .loading }
        try await f.collapse()
        try await f.wait { (try? f.sample().greenComponent) ?? 0 > 0.85 }
        let restarted = try f.sample("C-waiting-after-collapse")
        #expect(restarted.greenComponent > 0.85 && restarted.redComponent < 0.15,
                "A replacement must retain the revealed B artwork")
        // C is held without metadata until the old photo has been measured.
        f.engine.emit(.trackChanged(f.c))
        f.engine.emit(.paused(positionMs: 0))
        try await f.wait {
            guard let color = try? f.sample() else { return false }
            return color.blueComponent > 0.95 && color.redComponent < 0.1
        }
        let completed = try f.sample("C-final")
        #expect(completed.blueComponent > 0.85 && completed.redComponent < 0.15)
        print("HANDOFF_AUDIT interrupted A->B->C: before=\(f.rgb(before)) waiting=\(f.rgb(restarted)) final=\(f.rgb(completed)) C_elapsed=\(Date().timeIntervalSince(secondLaunch))")
    }

    @Test func repeatedIdenticalRejectionEndsTheReplacementPreview() async throws {
        let f = try await HandoffAuditFixture.make()
        defer { f.close() }
        f.engine.emit(.commandRejected("unavailable"))
        try await f.wait { f.player.commandNotice != nil }
        let existingNotice = f.player.commandNotice
        try f.clickCenter()
        try await f.wait { f.engine.loadRequests.count == 1 }
        f.engine.emit(.loading)
        try await f.wait { f.player.state.phase == .loading }
        try await f.collapse()
        f.engine.emit(.commandRejected("unavailable"))
        f.engine.emit(.trackChanged(f.b))
        try await f.wait { f.player.state.currentTrack?.uri == f.b.uri }
        #expect(f.player.commandNotice == existingNotice)
        try await f.wait { (try? f.sample().greenComponent) ?? 0 > 0.85 }
        #expect(try f.sample().redComponent < 0.15)
    }

    @Test func aCollectionWaitsForItsMatchingPlaybackContext() async throws {
        let f = try await HandoffAuditFixture.make(collection: true)
        defer { f.close() }
        try f.clickCenter()
        try await f.wait { f.engine.loadRequests.count == 1 }
        try await f.collapse()
        f.engine.emit(.recoveryIdentity(PlaybackIdentity(trackURI: f.b.uri, contextURI: "spotify:album:other")))
        f.engine.emit(.trackChanged(f.b))
        f.engine.emit(.paused(positionMs: 0))
        try await f.wait { f.player.state.currentTrack?.uri == f.b.uri }
        try await Task.sleep(for: .milliseconds(950))
        #expect(try f.sample().redComponent > 0.85, "An unrelated context cannot confirm this collection load")
        f.engine.emit(.recoveryIdentity(PlaybackIdentity(trackURI: f.b.uri, contextURI: f.collectionURI.rawValue)))
        try await f.wait { (try? f.sample().greenComponent) ?? 0 > 0.85 }
    }

}

@MainActor private final class HandoffAuditFixture {
    let a: Track
    let b: Track
    let c: Track
    let collectionURI = SpotifyURI("spotify:album:0123456789012345678901")!
    let engine = LiveLyricTestEngine()
    let player: PlayerModel
    let store: ArtworkStore
    let environment: AppEnvironment
    let defaults: UserDefaults
    let suite: String
    let controller: PlayerWindowController
    let panel: StatusPanel
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)

    private init(collection: Bool) throws {
        func track(_ letter: String, _ id: String) -> Track {
            Track(uri: SpotifyURI("spotify:track:\(id)")!, title: letter,
                  artists: [ArtistSummary(name: "Audit")], albumTitle: nil,
                  artwork: Artwork(url: URL(string: "https://handoff-audit.invalid/\(letter).png")!), durationMs: 240_000)
        }
        a = track("A", "1111111111111111111111")
        b = track("B", "2222222222222222222222")
        c = track("C", "3333333333333333333333")
        func art(_ color: NSColor) -> NSImage {
            NSImage(size: NSSize(width: 160, height: 160), flipped: false) { rect in
                color.setFill(); rect.fill(); return true
            }
        }
        store = ArtworkStore(previewImages: [a.artwork!.url: art(.red), b.artwork!.url: art(.green), c.artwork!.url: art(.blue)])
        player = PlayerModel(engine: engine)
        player.applyPreviewEvents([.trackChanged(a), .paused(positionMs: 0)])
        player.start()
        let service = HandoffAuditLibrary(tracks: [b, c], collection:
            LibraryCollection(uri: collectionURI, title: "Unrelated collection", subtitle: "Audit", artwork: c.artwork))
        environment = AppEnvironment(previewPlayer: player, favoriteService: service,
            savedTracksService: service, collectionsService: service, artworkStore: store)
        environment.presentation.sendAttention(.visibility(true))
        environment.presentation.sendAttention(.keyboardFocus(true))
        suite = "\(NSTemporaryDirectory())bopify-handoff-audit-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(collection ? "library" : "liked", forKey: "library.tab")
        controller = PlayerWindowController(defaults: defaults)
        panel = StatusPanel(content: RecordPlayerView(player: player, artworkStore: store,
            presentation: environment.presentation, windowController: controller)
            .environment(environment).defaultAppStorage(defaults))
        panel.isReleasedWhenClosed = false
        controller.attach(to: panel)
        controller.apply(mode: .expanded, reduceMotion: true, visibleFrame: screen)
        panel.makeKeyAndOrderFront(nil)
    }

    static func make(collection: Bool = false) async throws -> HandoffAuditFixture {
        let f = try HandoffAuditFixture(collection: collection)
        _ = await f.store.loadPalette(f.a.artwork!.url)
        _ = await f.store.loadPalette(f.b.artwork!.url)
        _ = await f.store.loadPalette(f.c.artwork!.url)
        try await f.wait {
            f.input()?.input != nil && (collection ? !f.environment.collections.items.isEmpty : f.environment.likedSongs.tracks.count == 2)
        }
        try await f.wait { (try? f.sample().redComponent) ?? 0 > 0.85 }
        return f
    }

    func close() { panel.close(); player.stop(); defaults.removePersistentDomain(forName: suite) }

    func input() -> CoverFlowInput.InputView? {
        func visit(_ view: NSView?) -> CoverFlowInput.InputView? {
            if let input = view as? CoverFlowInput.InputView { return input }
            return view?.subviews.lazy.compactMap { visit($0) }.first
        }
        return visit(panel.contentView)
    }

    func clickCenter() throws {
        let input = try #require(input())
        let point = input.convert(CGPoint(x: input.bounds.midX, y: input.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            panel.sendEvent(try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)))
        }
    }

    func settleShelf() async throws {
        try await wait { input()?.input?.isAnimating == true }
        let input = try #require(input())
        for _ in 0..<180 where input.input?.isAnimating == true {
            input.input?.onFrame(1.0 / 60)
            await Task.yield()
        }
        try #require(input.input?.isAnimating == false)
    }

    func collapse() async throws {
        environment.presentation.sendAttention(.keyboardFocus(false))
        environment.presentation.sendAttention(.pointer(false))
        try await wait { environment.presentation.mode == .compact }
        controller.apply(mode: .compact, reduceMotion: true, visibleFrame: screen)
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    func sample(_ name: String? = nil) throws -> NSColor {
        let host = try #require(panel.contentView)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if let name, let png = bitmap.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: "/tmp/bopify-handoff-audit-\(name).png"))
        }
        let layout = controller.layout
        let point = CGPoint(x: layout.recordCenter.x + layout.recordDiameter * 0.1, y: layout.recordCenter.y)
        return try #require(bitmap.colorAt(x: Int(point.x * CGFloat(bitmap.pixelsWide) / host.bounds.width),
            y: Int(point.y * CGFloat(bitmap.pixelsHigh) / host.bounds.height))?.usingColorSpace(.deviceRGB))
    }

    func rgb(_ color: NSColor) -> String {
        "(\(color.redComponent),\(color.greenComponent),\(color.blueComponent),a=\(color.alphaComponent))"
    }

    func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition(), "Audit condition did not settle")
    }
}

private nonisolated struct HandoffAuditLibrary: LibraryService, SavedTracksService, LibraryCollectionsService {
    let tracks: [Track]
    let collection: LibraryCollection
    func savedState(for uri: SpotifyURI) async throws -> Bool { false }
    func save(_ uri: SpotifyURI) async throws {}
    func remove(_ uri: SpotifyURI) async throws {}
    func savedTracks(offset: Int, limit: Int) async throws -> SavedTracksPage { SavedTracksPage(tracks: tracks, nextOffset: nil) }
    func savedCollections(_ kind: LibraryCollectionKind, cursor: LibraryCollectionCursor, limit: Int) async throws -> LibraryCollectionsPage {
        LibraryCollectionsPage(items: kind == .albums ? [collection] : [], nextCursor: nil)
    }
}
