import AppKit
import Observation
import os
import ImageIO
import BopifyDomain

@MainActor
@Observable
final class ArtworkStore {
    private(set) var images: [URL: NSImage] = [:]
    @ObservationIgnored private var pending: [URL: Task<DecodedArtwork?, Never>] = [:]
    @ObservationIgnored private var recent: [URL] = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let decoder = ArtworkDecoder()

    @ObservationIgnored private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    #if DEBUG
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
        }
    }

    func clear() {
        generation += 1
        pending.values.forEach { $0.cancel() }
        pending.removeAll()
        images.removeAll()
        recent.removeAll()
    }
}

private nonisolated struct DecodedArtwork: Sendable {
    let image: CGImage
}

private actor ArtworkDecoder {
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
