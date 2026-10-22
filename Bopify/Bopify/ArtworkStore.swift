import AppKit
import Observation
import os
import CoreImage.CIFilterBuiltins
import Nuke
import BopifyDomain
import BopifyPlayback

struct ArtworkLoadRequest: Equatable {
    let url: URL?
    let retryRevision: Int
    var pixelSize: Int = 640
    var sessionRevision: Int = 0
}

struct LoadedArtwork {
    let image: NSImage
    let palette: ArtworkPalette
}

@MainActor
@Observable
final class ArtworkStore {
    private(set) var retryRevision = 0
    private(set) var sessionRevision = 0
    private var cacheRevision = 0
    private struct Failure {
        let retryAt: ContinuousClock.Instant
        let transport: Bool
        let transient: Bool
    }
    @ObservationIgnored private var failures: [URL: Failure] = [:]
    @ObservationIgnored private var failedURLs: [URL] = []
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var pendingPalettes: [URL: (id: UUID, image: NSImage, task: Task<ArtworkPalette?, Never>)] = [:]
    @ObservationIgnored private let decoder = ArtworkDecoder()
    @ObservationIgnored private let configuration: ImagePipeline.Configuration
    @ObservationIgnored private var pipeline: ImagePipeline
    @ObservationIgnored private var imageCache: ImageCache
    @ObservationIgnored private let httpCache: URLCache?
    @ObservationIgnored private let now: () -> ContinuousClock.Instant
    @ObservationIgnored private let sleep: (ContinuousClock.Instant) async throws -> Void

    init(configuration: URLSessionConfiguration? = nil, imageCache: ImageCache = ImageCache(costLimit: 32 * 1024 * 1024, countLimit: 112), now: @escaping () -> ContinuousClock.Instant = { .now },
         sleep: @escaping (ContinuousClock.Instant) async throws -> Void = { try await Task.sleep(until: $0, clock: .continuous) }) {
        self.now = now
        self.sleep = sleep
        let configuration = configuration ?? Self.httpConfiguration()
        httpCache = configuration.urlCache
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .useProtocolCachePolicy
        let loader = DataLoader(configuration: configuration) { response in
            guard let response = response as? HTTPURLResponse else { return URLError(.badServerResponse) }
            return (200..<300).contains(response.statusCode) ? nil : ArtworkHTTPFailure(response)
        }
        var settings = ImagePipeline.Configuration(dataLoader: loader)
        let cache = imageCache
        cache.entryCostLimit = 1
        settings.imageCache = cache
        settings.isResumableDataEnabled = false
        settings.maximumResponseDataSize = 8 * 1024 * 1024
        settings.dataLoadingQueue = TaskQueue(maxConcurrentOperationCount: 4)
        self.imageCache = cache
        pipeline = ImagePipeline(configuration: settings)
        // A reset template must not retain the previous session's cache.
        settings.imageCache = nil
        self.configuration = settings
    }

    private static func httpConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 0, diskCapacity: 150 * 1024 * 1024,
            directory: URL.cachesDirectory.appendingPathComponent("com.leesiongchan.bopify.artwork"))
        return configuration
    }

    convenience init(session: URLSession) { self.init(configuration: session.configuration) }

    #if DEBUG
    @ObservationIgnored private var paletteExtractor: (@Sendable (CGImage) async -> ArtworkPalette?)?
    convenience init(configuration: URLSessionConfiguration, imageCache: ImageCache, paletteExtractor: @escaping @Sendable (CGImage) async -> ArtworkPalette?) {
        self.init(configuration: configuration, imageCache: imageCache)
        self.paletteExtractor = paletteExtractor
    }

    convenience init(previewImages: [URL: NSImage]) {
        self.init()
        for (url, image) in previewImages {
            for size in [64, 160, 640] { pipeline.cache[request(url, pixelSize: size)] = ImageContainer(image: image) }
        }
    }
    #endif

    private func request(_ url: URL, pixelSize: Int = 640) -> ImageRequest {
        var request = ImageRequest(url: url)
        request.thumbnail = .init(maxPixelSize: Float(pixelSize))
        return request
    }

    private func container(for url: URL) -> ImageContainer? {
        _ = cacheRevision
        return pipeline.cache[request(url)]
    }

    func image(for url: URL) -> NSImage? { container(for: url)?.image }
    func palette(for url: URL) -> ArtworkPalette? {
        container(for: url)?.userInfo["bopify.palette"] as? ArtworkPalette
    }

    @discardableResult
    func load(_ url: URL, pixelSize: Int = 640) async -> ImageResponse? {
        guard url.scheme == "https" || url.scheme == "http", !Task.isCancelled else { return nil }
        let request = request(url, pixelSize: pixelSize)
        if let container = pipeline.cache[request] {
            return ImageResponse(container: container, request: request, cacheType: .memory)
        }
        if let failure = failures[url] {
            guard failure.retryAt <= now() else { return nil }
            removeFailure(url)
            scheduleRetry()
        }
        let pipeline = self.pipeline
        do {
            let response = try await pipeline.imageTask(with: request).response
            guard !Task.isCancelled, pipeline === self.pipeline else { return nil }
            removeFailure(url)
            cacheRevision += 1
            return response
        } catch {
            guard !Task.isCancelled, pipeline === self.pipeline, pipeline.cache[request] == nil else { return nil }
            if case .cancelled = error { return nil }
            let underlying = error.dataLoadingError
            let transport = underlying as? URLError
            if transport?.code == .cancelled { return nil }
            let http = underlying as? ArtworkHTTPFailure
            let retryableTransport = transport.map {
                [.timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                 .dnsLookupFailed, .notConnectedToInternet].contains($0.code)
            } ?? false
            let transient = retryableTransport || http.map { $0.status == 408 || $0.status == 429 || (500..<600).contains($0.status) } == true
            guard failures[url] == nil else { return nil }
            let delay = max(transient ? 30.0 : 600.0, http?.retryAfter ?? 0)
            failures[url] = Failure(retryAt: now().advanced(by: .seconds(delay)),
                                    transport: retryableTransport, transient: transient)
            failedURLs.append(url)
            while failedURLs.count > 112 { failures[failedURLs.removeFirst()] = nil }
            scheduleRetry()
            BopifyLog.playback.debug("artwork unavailable host=\(url.host ?? "", privacy: .public) status=\(http?.status ?? 0) transport=\(transport?.errorCode ?? 0) retrySeconds=\(delay) error=\(String(describing: error), privacy: .private)")
            return nil
        }
    }

    @discardableResult
    func loadPalette(_ url: URL) async -> LoadedArtwork? {
        let pipeline = self.pipeline
        guard let response = await load(url), !Task.isCancelled, pipeline === self.pipeline else { return nil }
        let image = response.image
        if let palette = response.container.userInfo["bopify.palette"] as? ArtworkPalette {
            return LoadedArtwork(image: image, palette: palette)
        }
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        if let pending = pendingPalettes[url], pending.image === image {
            let palette = await pending.task.value
            guard !Task.isCancelled, pipeline === self.pipeline, let palette else { return nil }
            return LoadedArtwork(image: image, palette: palette)
        }
        pendingPalettes[url]?.task.cancel()
        let id = UUID()
        #if DEBUG
        let extractor = paletteExtractor
        #endif
        let task = Task<ArtworkPalette?, Never> { [weak self, decoder] in
            let result: ArtworkPalette?
            #if DEBUG
            if let extractor { result = await extractor(cgImage) }
            else { result = await decoder.palette(cgImage) }
            #else
            result = await decoder.palette(cgImage)
            #endif
            guard let self, pendingPalettes[url]?.id == id else { return nil }
            pendingPalettes[url] = nil
            guard !Task.isCancelled, pipeline === self.pipeline else { return nil }
            let palette = result ?? ArtworkPalette.neutral
            if var container = container(for: url), container.image === image {
                container.userInfo["bopify.palette"] = palette
                pipeline.cache[request(url)] = container
                cacheRevision += 1
            }
            BopifyLog.playback.debug("artwork palette resolved")
            return palette
        }
        pendingPalettes[url] = (id, image, task)
        let palette = await task.value
        guard !Task.isCancelled, pipeline === self.pipeline, let palette else { return nil }
        return LoadedArtwork(image: image, palette: palette)
    }

    func retryFailedLoads(connectivityRestored: Bool = false) {
        let now = now()
        let eligible = failures.filter { $0.value.retryAt <= now || connectivityRestored && $0.value.transport }.map(\.key)
        guard !eligible.isEmpty else { return }
        eligible.forEach(removeFailure)
        retryRevision += 1
        scheduleRetry()
        BopifyLog.playback.debug("artwork recovery requested")
    }

    private func removeFailure(_ url: URL) {
        failures[url] = nil
        failedURLs.removeAll { $0 == url }
    }

    private func scheduleRetry() {
        retryTask?.cancel()
        retryTask = nil
        guard let deadline = failures.values.filter(\.transient).map(\.retryAt).min() else { return }
        retryTask = Task { [weak self, sleep] in
            do { try await sleep(deadline) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.retryFailedLoads()
        }
    }

    func clear() {
        retryTask?.cancel()
        retryTask = nil
        pipeline.invalidate()
        httpCache?.removeAllCachedResponses()
        sessionRevision += 1
        imageCache.removeAll()
        pendingPalettes.values.forEach { $0.task.cancel() }
        pendingPalettes.removeAll()
        failures.removeAll()
        failedURLs.removeAll()
        let cache = ImageCache(costLimit: 32 * 1024 * 1024, countLimit: 112)
        cache.entryCostLimit = 1
        imageCache = cache
        var settings = configuration
        settings.imageCache = cache
        pipeline = ImagePipeline(configuration: settings)
        cacheRevision += 1
    }
}

private nonisolated struct ArtworkHTTPFailure: Error {
    let status: Int
    let retryAfter: TimeInterval?

    init(_ response: HTTPURLResponse) {
        status = response.statusCode
        retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(Self.delay)
    }

    private static func delay(_ raw: String) -> TimeInterval? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 128 else { return nil }
        // Bound server-supplied delays to one day; no response may hold a task asleep indefinitely.
        if value.allSatisfy({ $0 >= "0" && $0 <= "9" }), let seconds = Double(value) {
            return min(86_400, seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = false
        for format in ["EEE, dd MMM yyyy HH:mm:ss 'GMT'", "EEEE, dd-MMM-yy HH:mm:ss 'GMT'", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return min(86_400, max(0, date.timeIntervalSinceNow)) }
        }
        return nil
    }
}

private actor ArtworkDecoder {
    private lazy var paletteContext = CIContext(options: [.outputPremultiplied: true])

    func palette(_ image: CGImage) -> ArtworkPalette? {
        guard !Task.isCancelled else { return nil }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let scale = min(1, 32 / CGFloat(max(image.width, image.height)))
        let width = max(1, Int(CGFloat(image.width) * scale))
        let height = max(1, Int(CGFloat(image.height) * scale))
        guard let thumbnail = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                        bytesPerRow: width * 4, space: space,
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        thumbnail.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let normalized = thumbnail.makeImage() else { return nil }
        let small = CIImage(cgImage: normalized)
        let filter = CIFilter.kMeans()
        filter.inputImage = small
        filter.extent = small.extent
        filter.count = 3
        filter.passes = 5
        filter.perceptual = true
        // Explicit seeds keep clustering independent of undocumented default initialization.
        let means: [Float] = [0, 0, 0, 1, 0.5, 0.5, 0.5, 1, 1, 1, 1, 1]
        filter.inputMeans = CIImage(bitmapData: means.withUnsafeBytes { Data($0) }, bytesPerRow: 48,
                                   size: CGSize(width: 3, height: 1), format: .RGBAf, colorSpace: space)
        guard let output = filter.outputImage else { return nil }
        var pixels = [Float](repeating: 0, count: 12)
        // KMeans returns sRGB centres with weights in alpha, not ordinary premultiplied image pixels.
        // Read raw values to avoid dividing by those weights or applying the sRGB transfer function twice.
        pixels.withUnsafeMutableBytes {
            paletteContext.render(output, toBitmap: $0.baseAddress!, rowBytes: 48,
                                  bounds: CGRect(x: 0, y: 0, width: 3, height: 1), format: .RGBAf, colorSpace: nil)
        }
        let samples = stride(from: 0, to: 12, by: 4).map { index in
            (color: ArtworkColor(red: Double(pixels[index]), green: Double(pixels[index + 1]), blue: Double(pixels[index + 2])),
             weight: Double(pixels[index + 3]))
        }
        guard samples.contains(where: { $0.weight.isFinite && $0.weight > 0 }) else { return nil }
        return ArtworkPalette.classify(samples)
    }

}
