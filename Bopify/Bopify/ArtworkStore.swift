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
    private(set) var images: [URL: NSImage] = [:]
    private(set) var palettes: [URL: ArtworkPalette] = [:]
    private(set) var retryRevision = 0
    private struct ImageLoad {
        let id: UUID
        let task: Task<Void, Never>
        var consumers: [UUID: CheckedContinuation<Void, Never>]
    }
    @ObservationIgnored private var pending: [URL: ImageLoad] = [:]
    @ObservationIgnored private var pendingPalettes: [URL: (id: UUID, task: Task<ArtworkPalette?, Never>)] = [:]
    @ObservationIgnored private var failedPalettes: [URL: ContinuousClock.Instant] = [:]
    private struct Failure {
        let retryAt: ContinuousClock.Instant
        let transport: Bool
    }
    @ObservationIgnored private var failures: [URL: Failure] = [:]
    @ObservationIgnored private var failedURLs: [URL] = []
    @ObservationIgnored private var recent: [URL] = []
    @ObservationIgnored private var costs: [URL: Int] = [:]
    @ObservationIgnored private var totalCost = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let decoder = ArtworkDecoder()
    @ObservationIgnored private let configuration: ImagePipeline.Configuration
    @ObservationIgnored private var pipeline: ImagePipeline

    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let loader = DataLoader(configuration: configuration) { response in
            guard let response = response as? HTTPURLResponse else { return URLError(.badServerResponse) }
            return (200..<300).contains(response.statusCode) ? nil : ArtworkHTTPFailure(response)
        }
        var settings = ImagePipeline.Configuration(dataLoader: loader)
        // Observable dictionaries own retention; a second decoded/disk cache would outlive clear().
        settings.imageCache = nil
        settings.isResumableDataEnabled = false
        settings.maximumResponseDataSize = 8 * 1024 * 1024
        settings.dataLoadingQueue = TaskQueue(maxConcurrentOperationCount: 4)
        self.configuration = settings
        pipeline = ImagePipeline(configuration: settings)
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
        for (url, image) in previewImages { cache(image, for: url) }
    }
    #endif

    func load(_ url: URL) async {
        guard url.scheme == "https" || url.scheme == "http", !Task.isCancelled else { return }
        if images[url] != nil { touch(url); return }
        let consumer = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(); return }
                if var existing = pending[url] {
                    existing.consumers[consumer] = continuation
                    pending[url] = existing
                } else {
                    let version = generation, id = UUID()
                    let task = Task { [weak self] in
                        guard let self else { return }
                        await self.fetch(url, generation: version)
                        self.finish(url, requestID: id)
                    }
                    pending[url] = ImageLoad(id: id, task: task, consumers: [consumer: continuation])
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancelConsumer(url, consumer: consumer) }
        }
    }

    private func cancelConsumer(_ url: URL, consumer: UUID) {
        guard var request = pending[url], let continuation = request.consumers.removeValue(forKey: consumer) else { return }
        if request.consumers.isEmpty {
            pending[url] = nil
            request.task.cancel()
        } else { pending[url] = request }
        continuation.resume()
    }

    private func finish(_ url: URL, requestID: UUID) {
        guard let request = pending[url], request.id == requestID else { return }
        pending[url] = nil
        request.consumers.values.forEach { $0.resume() }
    }

    private func fetch(_ url: URL, generation version: Int) async {
        for attempt in 0..<3 {
            guard !Task.isCancelled, generation == version else { return }
            if images[url] != nil { touch(url); return }
            if let failure = failures[url], failure.retryAt > .now { return }
            var request = ImageRequest(url: url)
            request.thumbnail = .init(maxPixelSize: 640)
            do {
                // The retry job shares one budget; its cancellation propagates into Nuke.
                let image = try await pipeline.imageTask(with: request).image
                guard !Task.isCancelled, generation == version else { return }
                if images[url] == nil { cache(image, for: url) }
                removeFailure(url)
                failedPalettes[url] = nil
                return
            } catch {
                guard !Task.isCancelled, generation == version else { return }
                if case .cancelled = error { return }
                let underlying = error.dataLoadingError
                if let transport = underlying as? URLError, transport.code == .cancelled { return }
                let http = underlying as? ArtworkHTTPFailure
                let status = http?.status
                let serverDelay = http?.retryAfter ?? 0
                let transport = underlying as? URLError
                let retryableTransport = transport.map {
                    [.timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                     .dnsLookupFailed, .notConnectedToInternet].contains($0.code)
                } ?? false
                let transient = retryableTransport || status.map { $0 == 408 || $0 == 429 || (500..<600).contains($0) } == true
                if transient, attempt < 2, serverDelay <= 3 {
                    BopifyLog.playback.debug("artwork transient failure; retry scheduled")
                    do { try await Task.sleep(for: .seconds(max(Double(attempt + 1), serverDelay))) }
                    catch { return }
                    continue
                }
                recordFailure(url, transient: transient, transport: retryableTransport, serverDelay: serverDelay)
                BopifyLog.playback.debug("artwork unavailable; retry cooldown recorded")
                return
            }
        }
    }

    func loadPalette(_ url: URL) async {
        guard url.scheme == "https" || url.scheme == "http" else { return }
        let version = generation
        await load(url)
        guard !Task.isCancelled, generation == version else { return }
        guard palettes[url] == nil else { return }
        if let retryAt = failedPalettes[url], retryAt > .now { return }
        guard let image = images[url]?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let request: (id: UUID, task: Task<ArtworkPalette?, Never>)
        if let existing = pendingPalettes[url] {
            request = existing
        } else {
            #if DEBUG
            let extractor = paletteExtractor
            #endif
            let task = Task { [decoder] in
                #if DEBUG
                if let extractor { return await extractor(image) }
                #endif
                return await decoder.palette(image)
            }
            request = (UUID(), task)
            pendingPalettes[url] = request
        }
        let result = await request.task.value
        guard !Task.isCancelled, !request.task.isCancelled, generation == version, images[url] != nil,
              pendingPalettes[url]?.id == request.id else { return }
        pendingPalettes[url] = nil
        if let result {
            palettes[url] = result
            failedPalettes[url] = nil
            BopifyLog.playback.debug("artwork palette computed")
        } else {
            failedPalettes[url] = .now.advanced(by: .seconds(600))
            BopifyLog.playback.debug("artwork palette failed; retry cooldown recorded")
        }
    }

    func retryFailedLoads(connectivityRestored: Bool = false) {
        let now = ContinuousClock.now
        let eligible = failures.filter { $0.value.retryAt <= now || connectivityRestored && $0.value.transport }.map(\.key)
        let paletteURLs = failedPalettes.filter { $0.value <= now }.map(\.key)
        guard !eligible.isEmpty || !paletteURLs.isEmpty else { return }
        eligible.forEach(removeFailure)
        paletteURLs.forEach { failedPalettes[$0] = nil }
        retryRevision += 1
        BopifyLog.playback.debug("artwork recovery requested")
    }

    private func touch(_ url: URL) {
        recent.removeAll { $0 == url }
        recent.append(url)
    }

    private func cache(_ image: NSImage, for url: URL) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        images[url] = image
        costs[url] = cgImage.bytesPerRow * cgImage.height
        totalCost += costs[url]!
        touch(url)
        while recent.count > 112 || totalCost > 32 * 1024 * 1024 {
            let old = recent.removeFirst()
            totalCost -= costs.removeValue(forKey: old) ?? 0
            images[old] = nil
            palettes[old] = nil
            pendingPalettes.removeValue(forKey: old)?.task.cancel()
            failedPalettes[old] = nil
        }
    }

    private func recordFailure(_ url: URL, transient: Bool, transport: Bool, serverDelay: TimeInterval) {
        let cooldown = max(transient ? 30 : 600, serverDelay)
        failures[url] = Failure(retryAt: .now.advanced(by: .seconds(cooldown)), transport: transport)
        failedURLs.removeAll { $0 == url }
        failedURLs.append(url)
        while failedURLs.count > 112 { failures[failedURLs.removeFirst()] = nil }
    }

    private func removeFailure(_ url: URL) {
        failures[url] = nil
        failedURLs.removeAll { $0 == url }
    }

    func clear() {
        generation += 1
        pending.values.forEach {
            $0.task.cancel()
            $0.consumers.values.forEach { $0.resume() }
        }
        pending.removeAll()
        pipeline.invalidate()
        pipeline = ImagePipeline(configuration: configuration)
        pendingPalettes.values.forEach { $0.task.cancel() }
        pendingPalettes.removeAll()
        failedPalettes.removeAll()
        failures.removeAll()
        failedURLs.removeAll()
        palettes.removeAll()
        images.removeAll()
        costs.removeAll()
        totalCost = 0
        recent.removeAll()
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
