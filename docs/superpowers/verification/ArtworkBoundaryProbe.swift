import Foundation
import AppKit
import ImageIO
import BopifyPlayback

private nonisolated final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    enum Reply: Sendable { case http(Int, Data); case error(URLError.Code); case chunked([Data]); case retryAfter(Int, Data, String) }
    static let lock = NSLock()
    nonisolated(unsafe) static var replies: [String: [Reply]] = [:]
    nonisolated(unsafe) static var counts: [String: Int] = [:]
    nonisolated(unsafe) static var held: [String: [FixtureProtocol]] = [:]
    nonisolated(unsafe) static var heldPaths: Set<String> = []
    nonisolated(unsafe) static var stopCounts: [String: Int] = [:]
    nonisolated(unsafe) static var defaultData = Data()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "artwork.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { Self.lock.withLock { stopped = true; Self.stopCounts[request.url!.path, default: 0] += 1 } }
    override func startLoading() {
        let shouldHold = Self.lock.withLock {
            let path = request.url!.path
            Self.counts[path, default: 0] += 1
            if Self.heldPaths.contains(path) { Self.held[path, default: []].append(self); return true }
            return false
        }
        if !shouldHold { respond() }
    }
    func respond() {
        let reply: Reply? = Self.lock.withLock {
            guard !stopped else { return nil }
            let path = request.url!.path
            if var list = Self.replies[path], !list.isEmpty {
                let value = list.removeFirst(); Self.replies[path] = list; return value
            }
            return .http(200, Self.defaultData)
        }
        guard let reply else { return }
        switch reply {
        case let .http(status, data):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Length": "\(data.count)"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case let .retryAfter(status, data, value):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Retry-After": value])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case let .chunked(chunks):
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in chunks { client?.urlProtocol(self, didLoad: chunk) }
            client?.urlProtocolDidFinishLoading(self)
        case let .error(code): client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }
    static func plan(_ path: String, _ list: [Reply], hold: Bool = false) {
        lock.withLock { replies[path] = list; if hold { heldPaths.insert(path) } }
    }
    static func release(_ path: String) {
        let objects = lock.withLock { held.removeValue(forKey: path) ?? [] }
        for object in objects { object.respond() }
    }
    static func count(_ path: String) -> Int { lock.withLock { counts[path, default: 0] } }
    static func stops(_ path: String) -> Int { lock.withLock { stopCounts[path, default: 0] } }
}

private actor PaletteGate {
    private(set) var count = 0
    var waiters: [CheckedContinuation<ArtworkPalette?, Never>] = []
    func extract(_ image: CGImage) async -> ArtworkPalette? { count += 1; return await withCheckedContinuation { waiters.append($0) } }
    func release(_ palette: ArtworkPalette?) { waiters.removeFirst().resume(returning: palette) }
}
@main struct ArtworkBoundaryProbe {
    @MainActor static func main() async {
        setbuf(stdout, nil)
        let data = makeImage(); FixtureProtocol.defaultData = data
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]; config.urlCache = nil
        let palette = ArtworkPalette.tinted(ArtworkColor(red: 0.8, green: 0.2, blue: 0.1))
        let store = ArtworkStore(session: URLSession(configuration: config), paletteExtractor: { _ in palette })
        for (path, reply) in [("/retry-429", FixtureProtocol.Reply.http(429, data)), ("/retry-500", .http(500, data)), ("/retry-timeout", .error(.timedOut)), ("/retry-offline", .error(.notConnectedToInternet)), ("/retry-connection-lost", .error(.networkConnectionLost))] {
            FixtureProtocol.plan(path, [reply, .http(200, data)])
            await store.loadPalette(url(path))
            precondition(FixtureProtocol.count(path) == 2 && store.images[url(path)] != nil && store.palettes[url(path)] == palette, "Transient failure failed to recover")
            print("PASS transient recovery", path)
        }
        FixtureProtocol.plan("/third-attempt", [.http(503,data),.http(503,data),.http(200,data)])
        await store.loadPalette(url("/third-attempt"))
        precondition(FixtureProtocol.count("/third-attempt") == 3 && store.images[url("/third-attempt")] != nil)
        print("PASS third attempt recovers after two transient failures")
        FixtureProtocol.plan("/exhausted", [.error(.timedOut),.error(.timedOut),.error(.timedOut),.http(200,data)])
        await store.loadPalette(url("/exhausted")); await store.loadPalette(url("/exhausted"))
        precondition(FixtureProtocol.count("/exhausted") == 3 && store.images[url("/exhausted")] == nil)
        let revision = store.retryRevision
        store.retryFailedLoads(connectivityRestored: true)
        precondition(store.retryRevision != revision, "Recovery revision did not advance")
        await store.loadPalette(url("/exhausted"))
        precondition(FixtureProtocol.count("/exhausted") == 4 && store.images[url("/exhausted")] != nil && store.palettes[url("/exhausted")] == palette)
        print("PASS three-attempt budget, cooldown suppression, connectivity recovery at same URL, palette recovery")
        for (path, failure) in [("/permanent-404", FixtureProtocol.Reply.http(404,data)), ("/permanent-410", .http(410,data)), ("/decode-failure",.http(200,Data("invalid".utf8)))] {
            FixtureProtocol.plan(path,[failure,.http(200,data)])
            await store.loadPalette(url(path)); store.retryFailedLoads(connectivityRestored: true); await store.loadPalette(url(path))
            precondition(FixtureProtocol.count(path) == 1 && store.images[url(path)] == nil)
            print("PASS permanent/decode failures do not immediate-retry on connectivity event",path)
        }
        store.clear()
        await verifyCancellation(store,data:data)
        await verifyClear(store,data:data)
        await verifyBounds(store,data:data)
        await verifyPalettes(config,data:data,palette:palette)
        await verifySharedBudget(store, data: data)
        await verifyServerWait(store, data: data)
        if CommandLine.arguments.contains("--cooldown") { await verifyCooldown(store,data:data,palette:palette) }
        print("ALL ARTWORK ADAPTER BOUNDARY PROBES PASSED")
    }
    @MainActor static func verifyCancellation(_ store: ArtworkStore,data:Data) async {
        let path="/cancel-one"
        FixtureProtocol.plan(path,[.http(200,data)],hold:true)
        var firstReturned=false
        let first=Task { await store.load(url(path)); firstReturned=true }
        await wait { FixtureProtocol.count(path)==1 }
        let second=Task { await store.load(url(path)) }
        try? await Task.sleep(for:.milliseconds(30)); first.cancel()
        try? await Task.sleep(for:.milliseconds(30))
        print("TRACE cancelled consumer returned before survivor response:",firstReturned)
        precondition(firstReturned,"Cancelled consumer did not return independently of shared survivor")
        precondition(FixtureProtocol.stops(path)==0,"Cancelling one consumer stopped the shared transport")
        FixtureProtocol.release(path); await first.value; await second.value
        precondition(FixtureProtocol.count(path)==1 && store.images[url(path)] != nil)
        print("PASS coalescing and single-consumer cancellation preserve survivor")
        store.clear()
        let allPath="/cancel-all"
        FixtureProtocol.plan(allPath,[.http(200,data)],hold:true)
        let only=Task { await store.load(url(allPath)) }
        await wait { FixtureProtocol.count(allPath)==1 }; only.cancel(); await only.value
        await wait { FixtureProtocol.stops(allPath)==1 }
        precondition(store.images[url(allPath)]==nil)
        let next=Task { await store.load(url(allPath)) }
        await wait { FixtureProtocol.count(allPath)==2 }; FixtureProtocol.release(allPath); await next.value
        precondition(store.images[url(allPath)] != nil,"Consumer cancellation poisoned retry")
        print("PASS last-consumer cancellation cancels transport, publishes nothing, and does not poison retry")
        store.clear()
    }
    @MainActor static func verifyClear(_ store:ArtworkStore,data:Data) async {
        let path="/clear-inflight"
        FixtureProtocol.plan(path,[.http(200,data)],hold:true)
        let old=Task { await store.load(url(path)) }; await wait { FixtureProtocol.count(path)==1 }
        store.clear(); await old.value; await wait { FixtureProtocol.stops(path)==1 }
        precondition(store.images.isEmpty && store.palettes.isEmpty)
        let replacement=Task { await store.load(url(path)) }; await wait { FixtureProtocol.count(path)==2 }
        FixtureProtocol.release(path); await replacement.value
        precondition(store.images[url(path)] != nil)
        print("PASS clear cancels old pipeline and replacement pipeline reloads unchanged URL")
        store.clear()
    }
    @MainActor static func verifyBounds(_ store:ArtworkStore,data:Data) async {
        var oversized=data; oversized.append(Data(repeating:0,count:9*1024*1024))
        FixtureProtocol.plan("/oversized",[.http(200,oversized),.http(200,data)])
        await store.load(url("/oversized")); await store.load(url("/oversized"))
        precondition(FixtureProtocol.count("/oversized")==1 && store.images[url("/oversized")]==nil,"Oversized response accepted or retry storm")
        FixtureProtocol.plan("/oversized-unknown",[.chunked([data,Data(repeating:0,count:9*1024*1024)]),.http(200,data)])
        await store.load(url("/oversized-unknown")); await store.load(url("/oversized-unknown"))
        precondition(FixtureProtocol.count("/oversized-unknown")==1 && store.images[url("/oversized-unknown")]==nil)
        print("PASS response cap rejects 9MiB with known and absent Content-Length, with no immediate retry")
        store.clear()
        var pending:[Task<Void,Never>]=[]
        for index in 0..<20 { let path="/bounded-burst/\(index)"; FixtureProtocol.plan(path,[.http(200,data)],hold:true); pending.append(Task { await store.load(url(path)) }) }
        await wait { (0..<20).reduce(0) { $0+FixtureProtocol.count("/bounded-burst/\($1)") } == 4 }
        try? await Task.sleep(for:.milliseconds(40))
        precondition((0..<20).reduce(0) { $0+FixtureProtocol.count("/bounded-burst/\($1)") }==4,"More than four active loads")
        store.clear(); for task in pending { await task.value }
        precondition(store.images.isEmpty)
        print("PASS burst submits20 requests, starts4, clear cancels queued/in-flight work")
        for index in 0..<80 { await store.load(url("/retention/\(index)")) }
        var bytes=0
        for image in store.images.values { let cg=image.cgImage(forProposedRect:nil,context:nil,hints:nil)!; precondition(max(cg.width,cg.height)<=640); bytes += cg.bytesPerRow*cg.height }
        precondition(bytes<=32*1024*1024 && store.images.count<=112)
        precondition(store.images[url("/retention/0")]==nil && store.images[url("/retention/79")] != nil,"Retention did not evict least-recent image")
        print("PASS authoritative cache byte bound: retained=\(store.images.count), bytes=\(bytes), all thumbnails<=640")
        store.clear()
        for index in 0..<113 { let path="/negative-cap/\(index)"; FixtureProtocol.plan(path,[.http(404,data),.http(200,data)]); await store.load(url(path)) }
        await store.load(url("/negative-cap/0"))
        precondition(FixtureProtocol.count("/negative-cap/0")==2 && store.images[url("/negative-cap/0")] != nil,"Old negative entry did not evict at112")
        await store.load(url("/negative-cap/112"))
        precondition(FixtureProtocol.count("/negative-cap/112")==1)
        print("PASS negative cache evicts oldest failure after113 unique permanent failures")
        store.clear()
    }
    @MainActor static func verifyPalettes(_ config:URLSessionConfiguration,data:Data,palette:ArtworkPalette) async {
        let gate=PaletteGate()
        let store=ArtworkStore(session:URLSession(configuration:config),paletteExtractor:{ await gate.extract($0) })
        let target=url("/palette-failed")
        let first=Task { await store.loadPalette(target) }; await wait { await gate.count==1 }; await gate.release(nil); await first.value
        await store.loadPalette(target)
        let initialCount=await gate.count
        precondition(initialCount==1 && store.images[target] != nil && store.palettes[target]==nil)
        print("PASS extraction failure suppresses immediate repeated extraction while retaining image")
        store.clear()
        let recovered=Task { await store.loadPalette(target) }; await wait { await gate.count==2 }; await gate.release(palette); await recovered.value
        precondition(store.palettes[target]==palette)
        store.clear()
        let old=Task { await store.loadPalette(target) }; await wait { await gate.count==3 }; store.clear()
        let new=Task { await store.loadPalette(target) }; await wait { await gate.count==4 }
        await gate.release(palette); await old.value; precondition(store.palettes.isEmpty)
        let replacement=ArtworkPalette.tinted(ArtworkColor(red:0.1,green:0.7,blue:0.4))
        await gate.release(replacement); await new.value; precondition(store.palettes[target]==replacement)
        print("PASS clear resets extraction failure and rejects stale palette over replacement")
        store.clear()
        let evicted=Task { await store.loadPalette(target) }; await wait { await gate.count==5 }
        for index in 0..<112 { await store.load(url("/palette-eviction/\(index)")) }
        await gate.release(palette); await evicted.value
        precondition(store.images[target]==nil && store.palettes[target]==nil)
        print("PASS eviction rejects late palette result")
    }
    @MainActor static func verifySharedBudget(_ store: ArtworkStore, data: Data) async {
        let path = "/staggered-consumers"
        FixtureProtocol.plan(path, Array(repeating: .http(503, data), count: 100))
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask { await store.load(url(path)) }
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
        precondition(FixtureProtocol.count(path) == 3, "Staggered callers exceeded one URL's retry budget")
        precondition(store.images[url(path)] == nil)
        print("PASS twenty staggered consumers share three attempts")
    }

    @MainActor static func verifyServerWait(_ store: ArtworkStore, data: Data) async {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        for status in [429, 503] {
            for dateHeader in [false, true] {
                let path = "/server-wait-\(status)-\(dateHeader)"
                let value = dateHeader ? formatter.string(from: Date().addingTimeInterval(60)) : "60"
                FixtureProtocol.plan(path, [.retryAfter(status, data, value), .http(200, data)])
                await store.load(url(path))
                store.retryFailedLoads(connectivityRestored: true)
                await store.load(url(path))
                precondition(FixtureProtocol.count(path) == 1 && store.images[url(path)] == nil, "Retry-After was bypassed")
            }
        }
        print("PASS 429/503 server waits honor both seconds and HTTP-date across recovery events")
    }

    @MainActor static func verifyCooldown(_ store:ArtworkStore,data:Data,palette:ArtworkPalette) async {
        let path="/cooldown-expiry"
        FixtureProtocol.plan(path,[.http(503,data),.http(503,data),.http(503,data),.http(200,data)])
        await store.loadPalette(url(path)); await store.loadPalette(url(path))
        precondition(FixtureProtocol.count(path)==3)
        print("WAIT: verifying real 30-second cooldown expiry")
        try? await Task.sleep(for:.seconds(31))
        store.retryFailedLoads()
        await store.loadPalette(url(path))
        precondition(FixtureProtocol.count(path)==4 && store.images[url(path)] != nil && store.palettes[url(path)]==palette)
        print("PASS elapsed transient cooldown permits sameURL image+palette recovery")
    }
    static func url(_ path: String) -> URL { URL(string: "https://artwork.invalid" + path)! }
    @MainActor static func wait(_ condition: () async -> Bool) async {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !(await condition()) { precondition(ProcessInfo.processInfo.systemUptime < deadline, "Timed out waiting for fixture event"); try? await Task.sleep(for: .milliseconds(2)) }
    }
    static func makeImage() -> Data {
        let context = CGContext(data: nil, width: 1200, height: 1200, bitsPerComponent: 8, bytesPerRow: 4800, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1200, height: 1200))
        let data = NSMutableData(); let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil); precondition(CGImageDestinationFinalize(destination)); return data as Data
    }
}
