#if DEBUG
import AppKit
import Foundation
import ImageIO
import Observation
import Testing
import BopifyPlayback

@MainActor
@Suite("Artwork store", .serialized)
struct ArtworkStoreTests {
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
        await survivor.value
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
        await load.value
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
        await old.value
        try await artworkEventually { ArtworkProtocol.stops(url) == 1 }
        #expect(fixture.store.image(for: url) == nil)
        let fresh = Task { await fixture.store.load(url) }
        try await artworkEventually { ArtworkProtocol.count(url) == 2 }
        ArtworkProtocol.release(url)
        await fresh.value
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
        await first.value
        await second.value
        #expect(fixture.store.palette(for: url) == .neutral)

        let lateURL = fixture.url()
        let late = Task { await fixture.store.loadPalette(lateURL) }
        try await artworkEventually { await gate.count == 2 }
        fixture.store.clear()
        await gate.release()
        await late.value
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

    @Test(.timeLimit(.minutes(1))) func transientFailureWakesConsumersAfterCooldown() async throws {
        let fixture = ArtworkFixture()
        defer { fixture.store.clear() }
        let url = fixture.url()
        ArtworkProtocol.plan(url, status: 503)
        await fixture.store.load(url)
        try #require(ArtworkProtocol.count(url) == 1)
        #expect(fixture.store.image(for: url) == nil)
        await fixture.store.load(url)
        #expect(ArtworkProtocol.count(url) == 1)
        let revision = fixture.store.retryRevision
        try await artworkEventually(seconds: 45) { fixture.store.retryRevision > revision }
        await fixture.store.load(url)
        #expect(ArtworkProtocol.count(url) == 2)
        #expect(fixture.store.image(for: url) != nil)
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
        await old.value
        do { try await artworkEventually { await gate.count == 2 } }
        catch { await gate.release(); throw error }
        await gate.release()
        await replacement.value
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
        await caller.value
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
private func artworkEventually(seconds: Double = 2, _ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
    while !(await condition()), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(await condition(), "Artwork operation did not settle before the deadline")
}

@MainActor
private struct ArtworkFixture {
    let store: ArtworkStore
    init(extractor: (@Sendable (CGImage) async -> ArtworkPalette?)? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArtworkProtocol.self]
        let session = URLSession(configuration: configuration)
        if let extractor { store = ArtworkStore(session: session, paletteExtractor: extractor) }
        else { store = ArtworkStore(session: session) }
    }
    func url() -> URL { URL(string: "https://artwork.invalid/\(UUID().uuidString)")! }
    nonisolated static func png(size: Int = 1200) -> Data {
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1))
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
