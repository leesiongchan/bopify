import AppKit
import Observation
import os
import ImageIO
import CoreImage.CIFilterBuiltins
import BopifyDomain
import BopifyPlayback

@MainActor
@Observable
final class ArtworkStore {
    private(set) var images: [URL: NSImage] = [:]
    private(set) var palettes: [URL: ArtworkPalette] = [:]
    @ObservationIgnored private var pending: [URL: Task<DecodedArtwork?, Never>] = [:]
    @ObservationIgnored private var pendingPalettes: [URL: (id: UUID, task: Task<ArtworkPalette?, Never>)] = [:]
    @ObservationIgnored private var failedPalettes: Set<URL> = []
    @ObservationIgnored private var recent: [URL] = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let decoder = ArtworkDecoder()

    @ObservationIgnored private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    #if DEBUG
    @ObservationIgnored private var paletteExtractor: (@Sendable (CGImage) async -> ArtworkPalette?)?
    init(session: URLSession, paletteExtractor: @escaping @Sendable (CGImage) async -> ArtworkPalette?) {
        self.session = session
        self.paletteExtractor = paletteExtractor
    }

    init(previewImages: [URL: NSImage]) {
        session = .shared
        images = previewImages
        recent = Array(previewImages.keys)
    }
    #endif

    func load(_ url: URL) async {
        guard url.scheme == "https" || url.scheme == "http" else { return }
        if recent.contains(url) {
            recent.removeAll { $0 == url }
            recent.append(url)
            return
        }
        let version = generation
        let task: Task<DecodedArtwork?, Never>
        if let existing = pending[url] {
            task = existing
        } else {
            task = Task { [decoder, session] in
                do {
                    let (data, response) = try await session.data(from: url)
                    guard !Task.isCancelled, let response = response as? HTTPURLResponse,
                          (200..<300).contains(response.statusCode) else { return nil }
                    return await decoder.decode(data)
                } catch { return nil }
            }
            pending[url] = task
        }
        let result = await task.value
        guard generation == version, pending[url] != nil else { return }
        pending[url] = nil
        if let result {
            images[url] = NSImage(cgImage: result.image, size: .zero)
        } else {
            BopifyLog.playback.debug("artwork unavailable")
        }
        recent.append(url)
        while recent.count > 112 {
            let old = recent.removeFirst()
            images[old] = nil
            palettes[old] = nil
            pendingPalettes.removeValue(forKey: old)?.task.cancel()
            failedPalettes.remove(old)
        }
    }

    func loadPalette(_ url: URL) async {
        guard url.scheme == "https" || url.scheme == "http" else { return }
        let version = generation
        await load(url)
        guard generation == version else {
            BopifyLog.playback.debug("stale artwork palette discarded")
            return
        }
        guard palettes[url] == nil, !failedPalettes.contains(url) else { return }
        guard let image = images[url]?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            failedPalettes.insert(url)
            BopifyLog.playback.debug("artwork palette failed")
            return
        }
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
        guard !request.task.isCancelled, generation == version, images[url] != nil else {
            BopifyLog.playback.debug("stale artwork palette discarded")
            return
        }
        guard pendingPalettes[url]?.id == request.id else { return }
        pendingPalettes[url] = nil
        if let result {
            palettes[url] = result
            BopifyLog.playback.debug("artwork palette computed")
        } else {
            failedPalettes.insert(url)
            BopifyLog.playback.debug("artwork palette failed")
        }
    }

    func clear() {
        generation += 1
        pending.values.forEach { $0.cancel() }
        pending.removeAll()
        pendingPalettes.values.forEach { $0.task.cancel() }
        pendingPalettes.removeAll()
        failedPalettes.removeAll()
        palettes.removeAll()
        images.removeAll()
        recent.removeAll()
    }
}

private nonisolated struct DecodedArtwork: Sendable {
    let image: CGImage
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

    func decode(_ data: Data) -> DecodedArtwork? {
        guard !Task.isCancelled,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 640
              ] as CFDictionary) else { return nil }
        return DecodedArtwork(image: image)
    }
}
