#if DEBUG
import AppKit
import Foundation
import ImageIO
import MediaPlayer
import Network
import Nuke
import Observation
import SwiftUI
import BopifyDomain
import Testing
import BopifyPlayback

@MainActor
@Suite("Artwork store", .serialized)
struct ArtworkStoreTests {
    @Test(arguments: [1.0, 2.0]) func displayedCoverSurvivesUnrelatedCachePressure(scale: CGFloat) async throws {
        let fixture = ArtworkFixture()
        defer { fixture.store.clear() }
        let url = fixture.url()
        // Isolate one consumer so a cover-flow reflection cannot start a separate load after eviction.
        let (host, window) = artworkWindow(
            RemoteArtworkView(url: url, store: fixture.store, size: 76) { Color.gray }.frame(width: 76, height: 76))
        defer { window.close() }
        try await artworkEventually { ArtworkProtocol.count(url) == 1 }
        try await artworkEventually { self.redArea(in: host, snapshot: "before", scale: scale) > 1_000 }
        fixture.cache.removeAll()
        await fixture.store.load(fixture.url())
        try #require(fixture.store.image(for: url) == nil)
        try await Task.sleep(for: .milliseconds(100))
        try await artworkEventually { self.redArea(in: host, snapshot: "after", scale: scale) > 1_000 }
        #expect(ArtworkProtocol.count(url) == 1)
    }

    @Test func changedURLAndSessionRejectStaleDisplayedArtwork() async throws {
        let fixture = ArtworkFixture()
        defer { fixture.store.clear() }
        let oldURL = fixture.url()
        let newURL = fixture.url()
        ArtworkProtocol.plan(oldURL, data: ArtworkFixture.png(color: CGColor(red: 0, green: 0.8, blue: 0, alpha: 1)))
        ArtworkProtocol.hold(oldURL)
        func content(_ url: URL) -> some View {
            RemoteArtworkView(url: url, store: fixture.store, size: 32) { Color.gray }.frame(width: 76, height: 76)
        }
        let (host, window) = artworkWindow(content(oldURL))
        defer { window.close() }
        try await artworkEventually { ArtworkProtocol.count(oldURL) == 1 }
        let survivor = Task { await fixture.store.load(oldURL, pixelSize: 64) }
        try await Task.sleep(for: .milliseconds(30))
        host.rootView = content(newURL)
        try await artworkEventually { self.redArea(in: host) > 1_000 }
        ArtworkProtocol.release(oldURL)
        _ = await survivor.value
        try await Task.sleep(for: .milliseconds(100))
        #expect(redArea(in: host) > 1_000, "An old URL must not replace the current image")
        ArtworkProtocol.hold(newURL)
        fixture.store.clear()
        try await artworkEventually { ArtworkProtocol.count(newURL) == 2 }
        #expect(redArea(in: host) == 0, "Session reset must remove retained artwork")
        ArtworkProtocol.release(newURL)
        try await artworkEventually { self.redArea(in: host) > 1_000 }
    }

    @Test(arguments: [1.0, 2.0]) func playerKeepsRetainedArtworkWhenAnotherImageRetries(scale: CGFloat) async throws {
        let clock = ArtworkRetryClock()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArtworkProtocol.self]
        let cache = ImageCache(costLimit: 32 * 1024 * 1024)
        let store = ArtworkStore(configuration: configuration, imageCache: cache,
            now: { clock.now }, sleep: { try await clock.sleep(until: $0) })
        defer { store.clear() }
        let environment = makePreviewEnvironment(.paused, library: .empty)
        let player = try #require(environment.player)
        defer { player.stop() }
        let url = URL(string: "https://artwork.invalid/\(UUID().uuidString)")!
        let track = Track(uri: previewTracks[1].uri, title: "Retained player artwork", artists: [],
                          albumTitle: nil, artwork: Artwork(url: url), durationMs: 180_000)
        player.applyPreviewEvents([.trackChanged(track)])
        let content = RecordPlayerView(player: player, artworkStore: store, presentation: environment.presentation,
            windowController: environment.playerWindowController).environment(environment).frame(width: 380, height: 600)
        let (host, window) = artworkWindow(content)
        window.setContentSize(CGSize(width: 380, height: 600))
        defer { window.close() }
        try await artworkEventually { store.palette(for: url) != nil && self.redArea(in: host, scale: scale) > 1_000 }
        cache.removeAll()
        ArtworkProtocol.plan(url, status: 503)
        let other = URL(string: "https://artwork.invalid/\(UUID().uuidString)")!
        ArtworkProtocol.plan(other, status: 503)
        await store.load(other)
        try await artworkEventually { !clock.waits.isEmpty }
        let revision = store.retryRevision
        clock.advance(by: .seconds(30))
        try await artworkEventually { store.retryRevision > revision }
        try await Task.sleep(for: .milliseconds(100))
        #expect(ArtworkProtocol.count(url) == 1, "Unrelated retries must reuse the player's retained artwork")
        #expect(redArea(in: host, scale: scale) > 1_000)
    }

    @Test func mountedArtworkRecoversAfterTransientCooldown() async throws {
        let clock = ArtworkRetryClock()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArtworkProtocol.self]
        let store = ArtworkStore(configuration: configuration, now: { clock.now }, sleep: { try await clock.sleep(until: $0) })
        defer { store.clear() }
        let url = URL(string: "https://artwork.invalid/\(UUID().uuidString)")!
        ArtworkProtocol.plan(url, status: 503)
        let (host, window) = artworkWindow(
            RemoteArtworkView(url: url, store: store, size: 32) { Color.gray }.frame(width: 76, height: 76))
        defer { window.close() }
        try await artworkEventually { !clock.waits.isEmpty }
        #expect(redArea(in: host) == 0)
        clock.advance(by: .seconds(30))
        try await artworkEventually { self.redArea(in: host) > 1_000 }
        #expect(ArtworkProtocol.count(url) == 2)
    }

    private func artworkWindow<Content: View>(_ content: Content) -> (NSHostingView<Content>, NSWindow) {
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: CGRect(x: 300, y: 300, width: 76, height: 76),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        return (host, window)
    }

    @Test func nowPlayingRetainsArtworkUntilTheURLChangesOrIsReleased() async throws {
        let fixture = ArtworkFixture()
        defer { fixture.store.clear() }
        let url = fixture.url()
        let response = try #require(await fixture.store.load(url))
        var artwork = NowPlayingArtwork()
        func select(_ url: URL?, image: NSImage?) -> MPMediaItemArtwork? { artwork.item(for: url, image: image) }
        let first = try #require(select(url, image: response.image))
        fixture.cache.removeAll()
        #expect(select(url, image: fixture.store.image(for: url)) === first)
        #expect(select(fixture.url(), image: nil) == nil)
        #expect(select(url, image: nil) == nil)
        _ = select(url, image: response.image)
        #expect(select(nil, image: nil) == nil)
        #expect(select(url, image: nil) == nil)
    }

    @Test func thumbnailsUseTheRequestedPixelSize() async throws {
        let fixture = ArtworkFixture()
        defer { fixture.store.clear() }
        let url = fixture.url()
        let small = try #require(await fixture.store.load(url, pixelSize: 64))
        let cover = try #require(await fixture.store.load(url, pixelSize: 160))
        #expect(small.image.cgImage(forProposedRect: nil, context: nil, hints: nil)?.width == 64)
        #expect(cover.image.cgImage(forProposedRect: nil, context: nil, hints: nil)?.width == 160)
    }

    @Test func httpCacheSurvivesImageEvictionAndIsClearedWithTheSession() async throws {
        let server = try ArtworkHTTPServer(data: ArtworkFixture.png(size: 32))
        let url = try await server.start()
        defer { server.stop() }
        let httpCache = URLCache(memoryCapacity: 8 * 1024 * 1024, diskCapacity: 0)
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = httpCache
        let cache = ImageCache(costLimit: 32 * 1024 * 1024)
        let store = ArtworkStore(configuration: configuration, imageCache: cache)
        defer { store.clear() }
        #expect(await store.load(url) != nil)
        try await artworkEventually { httpCache.cachedResponse(for: URLRequest(url: url)) != nil }
        cache.removeAll()
        #expect(await store.load(url) != nil)
        #expect(server.requests == 1)
        store.clear()
        #expect(httpCache.cachedResponse(for: URLRequest(url: url)) == nil)
    }

    @Test func sessionClearRejectsAnInFlightCacheableHTTPResponse() async throws {
        let server = try ArtworkHTTPServer(data: ArtworkFixture.png(size: 32), hold: true)
        let url = try await server.start()
        defer { server.stop() }
        let httpCache = URLCache(memoryCapacity: 8 * 1024 * 1024, diskCapacity: 0)
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = httpCache
        let store = ArtworkStore(configuration: configuration)
        defer { store.clear() }
        let old = Task { await store.load(url) }
        try await artworkEventually { server.requests == 1 }
        store.clear()
        server.release()
        #expect(await old.value == nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(httpCache.cachedResponse(for: URLRequest(url: url)) == nil)
        #expect(await store.load(url) != nil)
        #expect(server.requests == 2)
    }

    @Test func paletteLoadReturnsItsImageEvenWhenTheCacheEvictsIt() async throws {
        let gate = ArtworkPaletteGate()
        let fixture = ArtworkFixture(extractor: { await gate.extract($0) })
        defer { fixture.store.clear() }
        let url = fixture.url()
        let load = Task { await fixture.store.loadPalette(url) }
        try await artworkEventually { await gate.count == 1 }
        fixture.cache.removeAll()
        await gate.release()
        let artwork = try #require(await load.value)
        #expect(artwork.palette == .neutral)
        #expect(artwork.image.cgImage(forProposedRect: nil, context: nil, hints: nil) != nil)
        #expect(fixture.store.image(for: url) == nil)
    }

    private func redArea(in view: NSView, snapshot: String? = nil, scale: CGFloat = 1) -> CGFloat {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(view.bounds.width * scale), pixelsHigh: Int(view.bounds.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return 0 }
        bitmap.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        var count = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   color.redComponent > 0.6, color.greenComponent < 0.4, color.blueComponent < 0.3 { count += 1 }
            }
        }
        // Each sample covers four pixels; compare square points at either backing scale.
        let area = CGFloat(count * 4) / (scale * scale)
        if area > 1_000, let snapshot {
            try? bitmap.representation(using: .png, properties: [:])?.write(
                to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bopify-artwork-\(snapshot).png"))
        }
        return area
    }

    @Test func sharedLoadSurvivesOneCancellationAndThenUsesTheCache() async throws {
        let fixture = ArtworkFixture()
        defer { fixture.store.clear() }
        let url = fixture.url()
        ArtworkProtocol.hold(url)
        var cancelledReturned = false
        let cancelled = Task { await fixture.store.load(url); cancelledReturned = true }
        try await artworkEventually { ArtworkProtocol.count(url) == 1 }
        var survivorEntered = false
        let survivor = Task { survivorEntered = true; await fixture.store.load(url) }
        try await artworkEventually { survivorEntered }
        cancelled.cancel()
        try await artworkEventually { cancelledReturned }
        #expect(ArtworkProtocol.stops(url) == 0)
        ArtworkProtocol.release(url)
        _ = await survivor.value
        #expect(fixture.store.image(for: url) != nil)
        await fixture.store.load(url)
        #expect(ArtworkProtocol.count(url) == 1)
    }

    @Test func cancellingTheLastConsumerStopsItsTransport() async throws {
        let fixture = ArtworkFixture()
        defer { fixture.store.clear() }
        let url = fixture.url()
        ArtworkProtocol.hold(url)
        let load = Task { await fixture.store.load(url) }
        try await artworkEventually { ArtworkProtocol.count(url) == 1 }
        load.cancel()
        _ = await load.value
        try await artworkEventually { ArtworkProtocol.stops(url) == 1 }
        #expect(fixture.store.image(for: url) == nil)
    }

    @Test func clearRejectsOldWorkAndAllowsTheSameURLAgain() async throws {
        let fixture = ArtworkFixture()
        defer { fixture.store.clear() }
        let url = fixture.url()
        ArtworkProtocol.hold(url)
        let old = Task { await fixture.store.load(url) }
        try await artworkEventually { ArtworkProtocol.count(url) == 1 }
        fixture.store.clear()
        _ = await old.value
        try await artworkEventually { ArtworkProtocol.stops(url) == 1 }
        #expect(fixture.store.image(for: url) == nil)
        let fresh = Task { await fixture.store.load(url) }
        try await artworkEventually { ArtworkProtocol.count(url) == 2 }
        ArtworkProtocol.release(url)
        _ = await fresh.value
        #expect(fixture.store.image(for: url) != nil)
    }

    @Test func imagePublicationIsObservable() async throws {
        let fixture = ArtworkFixture()
        defer { fixture.store.clear() }
        let url = fixture.url()
        let changed = ArtworkFlag()
        withObservationTracking { _ = fixture.store.image(for: url) } onChange: { changed.set() }
        await fixture.store.load(url)
        #expect(changed.value)
        #expect(fixture.store.image(for: url) != nil)
    }

    @Test func paletteExtractionIsSharedAndClearRejectsItsLateResult() async throws {
        let gate = ArtworkPaletteGate()
        let fixture = ArtworkFixture(extractor: { await gate.extract($0) })
        defer { fixture.store.clear() }
        let url = fixture.url()
        let first = Task { await fixture.store.loadPalette(url) }
        try await artworkEventually { await gate.count == 1 }
        let second = Task { await fixture.store.loadPalette(url) }
        await Task.yield()
        #expect(await gate.count == 1)
        await gate.release()
        _ = await first.value
        _ = await second.value
        #expect(fixture.store.palette(for: url) == .neutral)

        let lateURL = fixture.url()
        let late = Task { await fixture.store.loadPalette(lateURL) }
        try await artworkEventually { await gate.count == 2 }
        fixture.store.clear()
        await gate.release()
        _ = await late.value
        #expect(fixture.store.palette(for: lateURL) == nil)
        #expect(fixture.store.image(for: lateURL) == nil)
    }

    @Test func imageAndPaletteRetentionStayWithinTheByteBudget() async throws {
        let fixture = ArtworkFixture(extractor: { _ in .neutral })
        defer { fixture.store.clear() }
        let urls = (0..<40).map { _ in fixture.url() }
        for url in urls { await fixture.store.loadPalette(url) }
        let retained = urls.filter { fixture.store.image(for: $0) != nil }
        #expect(!retained.isEmpty)
        #expect(retained.count <= 20)
        for url in urls where fixture.store.image(for: url) == nil {
            #expect(fixture.store.palette(for: url) == nil)
        }
    }

    @Test func smallImagesStayWithinTheEntryLimit() async throws {
        let fixture = ArtworkFixture()
        defer { fixture.store.clear() }
        let urls = (0..<120).map { _ in fixture.url() }
        for url in urls {
            ArtworkProtocol.plan(url, status: 200, data: ArtworkFixture.png(size: 16))
            await fixture.store.load(url)
        }
        #expect(urls.filter { fixture.store.image(for: $0) != nil }.count == 112)
    }

    @Test func transientFailureWakesConsumersAfterCooldown() async throws {
        let clock = ArtworkRetryClock()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArtworkProtocol.self]
        let store = ArtworkStore(configuration: configuration, now: { clock.now }, sleep: { try await clock.sleep(until: $0) })
        defer { store.clear() }
        let url = URL(string: "https://artwork.invalid/\(UUID().uuidString)")!
        ArtworkProtocol.plan(url, status: 503)
        await store.load(url)
        try #require(ArtworkProtocol.count(url) == 1)
        #expect(store.image(for: url) == nil)
        await store.load(url)
        #expect(ArtworkProtocol.count(url) == 1)
        let revision = store.retryRevision
        try await artworkEventually { !clock.waits.isEmpty }
        clock.advance(by: .seconds(29))
        await store.load(url)
        #expect(ArtworkProtocol.count(url) == 1)
        #expect(store.retryRevision == revision)
        clock.advance(by: .seconds(1))
        try await artworkEventually { store.retryRevision > revision }
        await store.load(url)
        #expect(ArtworkProtocol.count(url) == 2)
        #expect(store.image(for: url) != nil)
    }

    @Test func reconnectDoesNotBypassServerThrottling() async throws {
        let fixture = ArtworkFixture()
        defer { fixture.store.clear() }
        let url = fixture.url()
        ArtworkProtocol.plan(url, status: 429, headers: ["Retry-After": "120"])
        await fixture.store.load(url)
        fixture.store.retryFailedLoads(connectivityRestored: true)
        await fixture.store.load(url)
        #expect(ArtworkProtocol.count(url) == 1)
        #expect(fixture.store.image(for: url) == nil)
    }

    @Test func reconnectUnblocksTransportFailures() async throws {
        let fixture = ArtworkFixture()
        defer { fixture.store.clear() }
        let url = fixture.url()
        ArtworkProtocol.plan(url, error: .notConnectedToInternet)
        await fixture.store.load(url)
        try #require(ArtworkProtocol.count(url) == 1)
        fixture.store.retryFailedLoads(connectivityRestored: true)
        await fixture.store.load(url)
        #expect(ArtworkProtocol.count(url) == 2)
        #expect(fixture.store.image(for: url) != nil)
    }

    @Test func repeatedPermanentFailureRestartsItsCooldown() async throws {
        var now = ContinuousClock.now
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArtworkProtocol.self]
        let store = ArtworkStore(configuration: configuration, now: { now })
        defer { store.clear() }
        let url = URL(string: "https://artwork.invalid/\(UUID().uuidString)")!
        ArtworkProtocol.plan(url, status: 404)
        await store.load(url)
        now = now.advanced(by: .seconds(601))
        ArtworkProtocol.plan(url, status: 404)
        await store.load(url)
        try #require(ArtworkProtocol.count(url) == 2)
        await store.load(url)
        #expect(ArtworkProtocol.count(url) == 2)
    }

    @Test func replacementImageGetsItsOwnPaletteAfterEviction() async throws {
        let gate = ArtworkPaletteGate()
        let fixture = ArtworkFixture(extractor: { await gate.extract($0) })
        defer { fixture.store.clear() }
        let url = fixture.url()
        let old = Task { await fixture.store.loadPalette(url) }
        try await artworkEventually { await gate.count == 1 }
        for _ in 0..<40 { await fixture.store.load(fixture.url()) }
        try #require(fixture.store.image(for: url) == nil)
        await fixture.store.load(url)
        var replacementEntered = false
        let replacement = Task { replacementEntered = true; await fixture.store.loadPalette(url) }
        try await artworkEventually { replacementEntered }
        await gate.release()
        _ = await old.value
        do { try await artworkEventually { await gate.count == 2 } }
        catch { await gate.release(); throw error }
        await gate.release()
        _ = await replacement.value
        #expect(fixture.store.palette(for: url) == .neutral)
    }

    @Test func failedPaletteExtractionCachesTheNeutralFallbackOnce() async throws {
        let gate = ArtworkPaletteGate()
        let fixture = ArtworkFixture(extractor: { _ in await gate.fail() })
        defer { fixture.store.clear() }
        let url = fixture.url()
        await fixture.store.loadPalette(url)
        await fixture.store.loadPalette(url)
        #expect(fixture.store.palette(for: url) == .neutral)
        #expect(await gate.count == 1)
    }

    @Test func aCancelledPaletteWaiterDoesNotOrphanTheCompletedExtraction() async throws {
        let gate = ArtworkPaletteGate()
        let fixture = ArtworkFixture(extractor: { await gate.extract($0) })
        defer { fixture.store.clear() }
        let url = fixture.url()
        let caller = Task { await fixture.store.loadPalette(url) }
        try await artworkEventually { await gate.count == 1 }
        caller.cancel()
        await gate.release()
        _ = await caller.value
        await fixture.store.loadPalette(url)
        #expect(fixture.store.palette(for: url) == .neutral)
        #expect(await gate.count == 1)
    }

    @Test func extractsAPaletteThroughCoreImage() async throws {
        let fixture = ArtworkFixture()
        defer { fixture.store.clear() }
        let url = fixture.url()
        await fixture.store.loadPalette(url)
        #expect(fixture.store.palette(for: url) != nil)
        #expect(fixture.store.palette(for: url) != .neutral)
    }
}

@MainActor
private final class ArtworkRetryClock {
    var now = ContinuousClock.now
    private(set) var waits: [UUID: (ContinuousClock.Instant, CheckedContinuation<Void, any Error>)] = [:]

    func sleep(until deadline: ContinuousClock.Instant) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                if deadline <= now { continuation.resume(); return }
                waits[id] = (deadline, continuation)
            }
        } onCancel: { Task { @MainActor in self.waits.removeValue(forKey: id)?.1.resume(throwing: CancellationError()) } }
    }

    func advance(by duration: Duration) {
        now = now.advanced(by: duration)
        for id in waits.filter({ $0.value.0 <= now }).keys { waits.removeValue(forKey: id)?.1.resume() }
    }
}

@MainActor
private func artworkEventually(seconds: Double = 2, _ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
    while !(await condition()), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(await condition(), "Artwork operation did not settle before the deadline")
}

private nonisolated final class ArtworkHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let response: Data
    private let lock = NSLock()
    private var count = 0
    private var holding: Bool
    private var pending: [NWConnection] = []
    var requests: Int { lock.withLock { count } }

    init(data: Data, hold: Bool = false) throws {
        holding = hold
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let headers = "HTTP/1.1 200 OK\r\nDate: \(formatter.string(from: Date()))\r\nCache-Control: public, max-age=3600\r\nContent-Type: image/png\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        response = Data(headers.utf8) + data
    }

    func start() async throws -> URL {
        listener.newConnectionHandler = { [self] connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [self] _, _, _, _ in
                let waiting = lock.withLock {
                    count += 1
                    if holding { pending.append(connection); return true }
                    return false
                }
                if !waiting { send(connection) }
            }
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                if case .ready = state, let port = listener.port {
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: port.rawValue)
                } else if case let .failed(error) = state {
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                }
            }
            listener.start(queue: .main)
        }
        return URL(string: "http://127.0.0.1:\(port)/cover.png")!
    }

    private func send(_ connection: NWConnection) {
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    func release() {
        let connections = lock.withLock { holding = false; let connections = pending; pending = []; return connections }
        connections.forEach(send)
    }

    func stop() { release(); listener.newConnectionHandler = nil; listener.cancel() }
}

@MainActor
private struct ArtworkFixture {
    let store: ArtworkStore
    let cache = ImageCache(costLimit: 32 * 1024 * 1024, countLimit: 112)
    init(extractor: (@Sendable (CGImage) async -> ArtworkPalette?)? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArtworkProtocol.self]
        if let extractor { store = ArtworkStore(configuration: configuration, imageCache: cache, paletteExtractor: extractor) }
        else { store = ArtworkStore(configuration: configuration, imageCache: cache) }
    }
    func url() -> URL { URL(string: "https://artwork.invalid/\(UUID().uuidString)")! }
    nonisolated static func png(size: Int = 1200, color: CGColor = CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1)) -> Data {
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

private actor ArtworkPaletteGate {
    private(set) var count = 0
    private var continuations: [CheckedContinuation<ArtworkPalette?, Never>] = []
    func extract(_ image: CGImage) async -> ArtworkPalette? {
        count += 1
        return await withCheckedContinuation { continuations.append($0) }
    }
    func release() {
        if !continuations.isEmpty { continuations.removeFirst().resume(returning: .neutral) }
    }
    func fail() -> ArtworkPalette? { count += 1; return nil }
}

private nonisolated final class ArtworkFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var changed = false
    func set() { lock.withLock { changed = true } }
    var value: Bool { lock.withLock { changed } }
}

private nonisolated final class ArtworkProtocol: URLProtocol, @unchecked Sendable {
    private struct Reply { var status = 200; var data: Data?; var headers: [String: String] = [:]; var error: URLError.Code? }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [URL: Reply] = [:]
    nonisolated(unsafe) private static var counts: [URL: Int] = [:]
    nonisolated(unsafe) private static var stopCounts: [URL: Int] = [:]
    nonisolated(unsafe) private static var held: [URL: [ArtworkProtocol]] = [:]
    nonisolated(unsafe) private static var heldURLs: Set<URL> = []
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "artwork.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {
        Self.lock.withLock { stopped = true; Self.stopCounts[request.url!, default: 0] += 1 }
    }
    override func startLoading() {
        let waiting = Self.lock.withLock {
            let url = request.url!
            Self.counts[url, default: 0] += 1
            if Self.heldURLs.contains(url) { Self.held[url, default: []].append(self); return true }
            return false
        }
        if !waiting { respond() }
    }
    private func respond() {
        let reply = Self.lock.withLock { stopped ? nil : Self.replies.removeValue(forKey: request.url!) ?? Reply() }
        guard let reply else { return }
        if let error = reply.error { client?.urlProtocol(self, didFailWithError: URLError(error)); return }
        let data = reply.data ?? ArtworkFixture.png()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: reply.status,
            httpVersion: nil, headerFields: reply.headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    static func hold(_ url: URL) { lock.withLock { _ = heldURLs.insert(url) } }
    static func release(_ url: URL) {
        let pending = lock.withLock { heldURLs.remove(url); return held.removeValue(forKey: url) ?? [] }
        pending.forEach { $0.respond() }
    }
    static func plan(_ url: URL, status: Int = 200, data: Data? = nil, headers: [String: String] = [:], error: URLError.Code? = nil) {
        lock.withLock { replies[url] = Reply(status: status, data: data, headers: headers, error: error) }
    }
    static func count(_ url: URL) -> Int { lock.withLock { counts[url, default: 0] } }
    static func stops(_ url: URL) -> Int { lock.withLock { stopCounts[url, default: 0] } }
}
#endif
