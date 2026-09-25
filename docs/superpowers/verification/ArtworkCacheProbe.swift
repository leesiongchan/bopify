import Foundation
import AppKit
import ImageIO

private final class ArtworkProtocol: URLProtocol, @unchecked Sendable {
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
        precondition(store.images.count == 1 && store.palettes.count == 1)
        precondition(store.images[url]!.size.width <= 640, "Image not downsampled")
        for path in ["failure", "invalid"] {
            let failed = URL(string: "https://artwork.invalid/\(path)")!
            await store.load(failed)
            await store.load(failed)
            precondition(store.images[failed] == nil && store.palettes[failed] == nil)
        }
        precondition(ArtworkProtocol.requestCount == 3, "Failure retried without an explicit reset")
        for index in 0..<115 { await store.load(URL(string: "https://artwork.invalid/cache/\(index)")!) }
        precondition(store.images.count == 112 && store.palettes.count == 112, "Unbounded cache")
        store.clear()
        precondition(store.images.isEmpty && store.palettes.isEmpty)
        await store.load(url)
        precondition(store.images.count == 1, "Cache did not recover after clear")
        print("PASS: coalescing, palette publication, 640px downsampling, HTTP/decode failure caching, 112-entry cap, clear/reload")
    }
}
