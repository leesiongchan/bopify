import Foundation
import AppKit
import ImageIO
import BopifyPlayback

private actor PaletteGate {
    private(set) var count = 0
    private var waiting: [CheckedContinuation<ArtworkPalette?, Never>] = []
    func extract(_ image: CGImage) async -> ArtworkPalette? {
        count += 1
        return await withCheckedContinuation { waiting.append($0) }
    }
    func release(_ palette: ArtworkPalette?) { waiting.removeFirst().resume(returning: palette) }
}

private nonisolated final class ArtworkProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var count = 0
    nonisolated(unsafe) static var imageData = Data()
    static let started = AsyncStream<Void>.makeStream()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "artwork.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.lock.withLock { Self.count += 1 }
        Self.started.continuation.yield(())
        let status = request.url!.path == "/failure" ? 503 : 200
        let data = request.url!.path == "/invalid" ? Data("invalid".utf8) : Self.imageData
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    static var requestCount: Int { lock.withLock { count } }
}

@main struct ArtworkCacheProbe {
    @MainActor static func main() async {
        let context = CGContext(data: nil, width: 1200, height: 1200, bitsPerComponent: 8, bytesPerRow: 4800,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1200, height: 1200))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        ArtworkProtocol.imageData = data as Data
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArtworkProtocol.self]
        let store = ArtworkStore(session: URLSession(configuration: configuration))
        let url = URL(string: "https://artwork.invalid/one")!
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 { group.addTask { await store.load(url) } }
        }
        precondition(ArtworkProtocol.requestCount == 1, "Duplicate artwork fetch")
        precondition(store.images.count == 1)
        precondition(store.images[url]!.size.width <= 640, "Image not downsampled")
        for path in ["failure", "invalid"] {
            let failed = URL(string: "https://artwork.invalid/\(path)")!
            await store.load(failed)
            await store.load(failed)
            precondition(store.images[failed] == nil)
        }
        precondition(ArtworkProtocol.requestCount == 5, "Transient retries or cooldown suppression changed")
        for index in 0..<115 { await store.load(URL(string: "https://artwork.invalid/cache/\(index)")!) }
        let bytes = store.images.values.reduce(0) { total, image in
            guard let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return total }
            return total + bitmap.bytesPerRow * bitmap.height
        }
        precondition(store.images.count <= 112 && bytes <= 32 * 1024 * 1024, "Unbounded cache")
        store.clear()
        precondition(store.images.isEmpty)
        await store.load(url)
        precondition(store.images.count == 1, "Cache did not recover after clear")
        await verifyPalettes(configuration: configuration, url: url)
        await verifyExtraction()
        print("PASS: coalescing, image publication, 640px downsampling, bounded transient retries, finite failure cooldowns, 32MiB/112-entry cap, clear/reload")
    }

    @MainActor private static func wait(_ gate: PaletteGate, count: Int) async {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while await gate.count < count {
            precondition(ProcessInfo.processInfo.systemUptime < deadline, "Palette request did not start")
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @MainActor static func verifyPalettes(configuration: URLSessionConfiguration, url: URL) async {
        let gate = PaletteGate()
        let palette = ArtworkPalette.marble(ArtworkColor(red: 1, green: 0, blue: 0),
                                           ArtworkColor(red: 0, green: 1, blue: 0),
                                           ArtworkColor(red: 0, green: 0, blue: 1))
        let replacement = ArtworkPalette.tinted(ArtworkColor(red: 0.5, green: 0.5, blue: 0.5))
        let store = ArtworkStore(session: URLSession(configuration: configuration), paletteExtractor: { await gate.extract($0) })
        for index in 0..<10 { await store.load(URL(string: "https://artwork.invalid/thumb/\(index)")!) }
        let lazyCount = await gate.count
        precondition(lazyCount == 0 && store.palettes.isEmpty, "Thumbnail loads eagerly extract palettes")
        await store.load(url)
        let fetched = ArtworkProtocol.requestCount
        let coalesced = Task {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<10 { group.addTask { await store.loadPalette(url) } }
            }
        }
        await wait(gate, count: 1)
        await gate.release(palette)
        await coalesced.value
        let coalescedCount = await gate.count
        precondition(coalescedCount == 1 && store.palettes[url] == palette, "Palette requests did not coalesce/publish")
        precondition(ArtworkProtocol.requestCount == fetched, "Palette downloaded already-decoded artwork again")
        for index in 0..<112 { await store.load(URL(string: "https://artwork.invalid/published-evict/\(index)")!) }
        precondition(store.images[url] == nil && store.palettes[url] == nil, "Published palette outlived its cached image")

        store.clear()
        let late = Task { await store.loadPalette(url) }
        await wait(gate, count: 2)
        store.clear()
        await gate.release(palette)
        await late.value
        precondition(store.palettes.isEmpty && store.images.isEmpty, "Clear accepted stale palette work")

        let old = Task { await store.loadPalette(url) }
        await wait(gate, count: 3)
        store.clear()
        let new = Task { await store.loadPalette(url) }
        await wait(gate, count: 4)
        await gate.release(palette)
        await old.value
        precondition(store.palettes.isEmpty, "Old generation published over replacement")
        await gate.release(replacement)
        await new.value
        precondition(store.palettes[url] == replacement, "Old task removed or overwrote the replacement task")

        store.clear()
        let evicted = Task { await store.loadPalette(url) }
        await wait(gate, count: 5)
        for index in 0..<112 { await store.load(URL(string: "https://artwork.invalid/palette-evict/\(index)")!) }
        await gate.release(palette)
        await evicted.value
        precondition(store.images[url] == nil && store.palettes[url] == nil, "Eviction accepted a late palette")

        let failed = Task { await store.loadPalette(url) }
        await wait(gate, count: 6)
        await gate.release(nil)
        await failed.value
        await store.loadPalette(url)
        let failedCount = await gate.count
        precondition(failedCount == 6 && store.palettes[url] == nil, "Palette failure did not respect its cooldown")
        for path in ["failure", "invalid"] {
            let failedURL = URL(string: "https://artwork.invalid/\(path)")!
            await store.loadPalette(failedURL)
            await store.loadPalette(failedURL)
            precondition(store.palettes[failedURL] == nil, "Failed image published a palette")
        }
        store.clear()
        precondition(store.palettes.isEmpty)
        print("PASS: lazy palettes, coalescing, decoded image reuse, clear/eviction/replacement races, failure cooldowns")
    }

    @MainActor static func verifyExtraction() async {
        func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> CGColor {
            CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [red, green, blue, 1])!
        }
        let fixtures: [[CGColor]] = [
            [rgb(0.9, 0.1, 0.2), rgb(0.1, 0.8, 0.9), rgb(0.2, 0.3, 0.9)],
            [rgb(0.9, 0.2, 0.05), rgb(1, 0.55, 0.1), rgb(0.4, 0.2, 0.1)],
            [rgb(0, 0, 0), rgb(0.5, 0.5, 0.5), rgb(1, 1, 1)],
            [rgb(0.8, 0.2, 0.1)],
        ]
        for (index, colours) in fixtures.enumerated() {
            let url = URL(string: "https://artwork.invalid/extraction/\(index)")!
            let context = CGContext(data: nil, width: 96, height: 96, bitsPerComponent: 8, bytesPerRow: 384,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            for (stripe, colour) in colours.enumerated() {
                context.setFillColor(colour)
                context.fill(CGRect(x: stripe * 96 / colours.count, y: 0, width: 96 / colours.count, height: 96))
            }
            let store = ArtworkStore(previewImages: [url: NSImage(cgImage: context.makeImage()!, size: .zero)])
            await store.loadPalette(url)
            guard let palette = store.palettes[url] else { preconditionFailure("Extraction did not publish") }
            print("PALETTE \(index): \(palette)")
            fflush(stdout)
            if index == 2 {
                guard case .tinted = palette else { preconditionFailure("Greyscale extraction was classified as marble") }
            } else {
                guard case let .marble(dominant, _, _) = palette else { preconditionFailure("Colourful extraction was classified as tinted") }
                if index == 3 {
                    precondition(abs(dominant.red - 0.8) < 0.08 && abs(dominant.green - 0.2) < 0.08
                                 && abs(dominant.blue - 0.1) < 0.08, "Extraction changed the solid-cover sRGB")
                }
            }
        }
    }
}
