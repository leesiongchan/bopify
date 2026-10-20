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
}

@MainActor
@Observable
final class ArtworkStore {
    private(set) var retryRevision = 0
    private var cacheRevision = 0
    private struct Failure {
        let retryAt: ContinuousClock.Instant
        let transport: Bool
        let transient: Bool
    }
    @ObservationIgnored private var failures: [URL: Failure] = [:]
    @ObservationIgnored private var failedURLs: [URL] = []
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var pendingPalettes: [URL: (id: UUID, image: NSImage, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private let decoder = ArtworkDecoder()
    @ObservationIgnored private let configuration: ImagePipeline.Configuration
    @ObservationIgnored private var pipeline: ImagePipeline
    @ObservationIgnored private var imageCache: ImageCache
    @ObservationIgnored private let now: () -> ContinuousClock.Instant
    @ObservationIgnored private let sleep: (ContinuousClock.Instant) async throws -> Void

    init(configuration: URLSessionConfiguration = .ephemeral, now: @escaping () -> ContinuousClock.Instant = { .now },
         sleep: @escaping (ContinuousClock.Instant) async throws -> Void = { try await Task.sleep(until: $0, clock: .continuous) }) {
        self.now = now
        self.sleep = sleep
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let loader = DataLoader(configuration: configuration) { response in
            guard let response = response as? HTTPURLResponse else { return URLError(.badServerResponse) }
            return (200..<300).contains(response.statusCode) ? nil : ArtworkHTTPFailure(response)
        }
        var settings = ImagePipeline.Configuration(dataLoader: loader)
        let cache = ImageCache(costLimit: 32 * 1024 * 1024, countLimit: 112)
        cache.entryCostLimit = 1
        settings.imageCache = cache
        settings.isResumableDataEnabled = false
        settings.maximumResponseDataSize = 8 * 1024 * 1024
        settings.dataLoadingQueue = TaskQueue(maxConcurrentOperationCount: 4)
        imageCache = cache
        pipeline = ImagePipeline(configuration: settings)
        // A reset template must not retain the previous session's cache.
        settings.imageCache = nil
        self.configuration = settings
    }

    convenience init(session: URLSession) { self.init(configuration: session.configuration) }

    #if DEBUG
    @ObservationIgnored private var paletteExtractor: (@Sendable (CGImage) async -> ArtworkPalette?)?
    convenience init(session: URLSession, paletteExtractor: @escaping @Sendable (CGImage) async -> ArtworkPalette?) {
        self.init(session: session)
        self.paletteExtractor = paletteExtractor
    }

    convenience init(previewImages: [URL: NSImage]) {
        self.init()
        for (url, image) in previewImages { pipeline.cache[request(url)] = ImageContainer(image: image) }
    }
    #endif

    private func request(_ url: URL) -> ImageRequest {
        var request = ImageRequest(url: url)
        request.thumbnail = .init(maxPixelSize: 640)
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

    func load(_ url: URL) async {
        guard url.scheme == "https" || url.scheme == "http", !Task.isCancelled,
              image(for: url) == nil else { return }
        if let failure = failures[url] {
            guard failure.retryAt <= now() else { return }
            removeFailure(url)
            scheduleRetry()
        }
        let pipeline = self.pipeline
        do {
            _ = try await pipeline.imageTask(with: request(url)).image
            guard !Task.isCancelled, pipeline === self.pipeline else { return }
            removeFailure(url)
            cacheRevision += 1
        } catch {
            guard !Task.isCancelled, pipeline === self.pipeline, image(for: url) == nil else { return }
            if case .cancelled = error { return }
            let underlying = error.dataLoadingError
            let transport = underlying as? URLError
            if transport?.code == .cancelled { return }
            let http = underlying as? ArtworkHTTPFailure
            let retryableTransport = transport.map {
                [.timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                 .dnsLookupFailed, .notConnectedToInternet].contains($0.code)
            } ?? false
            let transient = retryableTransport || http.map { $0.status == 408 || $0.status == 429 || (500..<600).contains($0.status) } == true
            guard failures[url] == nil else { return }
            failures[url] = Failure(retryAt: now().advanced(by: .seconds(max(transient ? 30 : 600, http?.retryAfter ?? 0))),
                                    transport: retryableTransport, transient: transient)
            failedURLs.append(url)
            while failedURLs.count > 112 { failures[failedURLs.removeFirst()] = nil }
            scheduleRetry()
            BopifyLog.playback.debug("artwork unavailable; retry cooldown recorded")
        }
    }

    func loadPalette(_ url: URL) async {
        let pipeline = self.pipeline
        await load(url)
        guard !Task.isCancelled, pipeline === self.pipeline, palette(for: url) == nil,
              let image = image(for: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        if let pending = pendingPalettes[url], pending.image === image { await pending.task.value; return }
        pendingPalettes[url]?.task.cancel()
        let id = UUID()
        #if DEBUG
        let extractor = paletteExtractor
        #endif
        let task = Task { [weak self, decoder] in
            let result: ArtworkPalette?
            #if DEBUG
            if let extractor { result = await extractor(cgImage) }
            else { result = await decoder.palette(cgImage) }
            #else
            result = await decoder.palette(cgImage)
            #endif
            guard let self, pendingPalettes[url]?.id == id else { return }
            pendingPalettes[url] = nil
            guard !Task.isCancelled, pipeline === self.pipeline,
                  var container = container(for: url), container.image === image else { return }
            // Extraction failure is stable for this image; retain the neutral appearance with it.
            container.userInfo["bopify.palette"] = result ?? ArtworkPalette.neutral
            pipeline.cache[request(url)] = container
            cacheRevision += 1
            BopifyLog.playback.debug("artwork palette resolved")
        }
        pendingPalettes[url] = (id, image, task)
        await task.value
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
