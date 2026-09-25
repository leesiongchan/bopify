import SwiftUI
import Observation
import os
import CoreImage.CIFilterBuiltins
import ImageIO
import BopifyDomain

struct ArtworkPalette {
    var primary: Color
    var secondary: Color
    static let neutral = ArtworkPalette(primary: Color(white: 0.16), secondary: Color(white: 0.1))
}

@MainActor
@Observable
final class ArtworkStore {
    private(set) var images: [URL: NSImage] = [:]
    private(set) var palettes: [URL: ArtworkPalette] = [:]
    @ObservationIgnored private var pending: [URL: Task<DecodedArtwork?, Never>] = [:]
    @ObservationIgnored private var recent: [URL] = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let decoder = ArtworkDecoder()

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
            task = Task { [decoder] in
                do {
                    let (data, response) = try await URLSession.shared.data(from: url)
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
            palettes[url] = ArtworkPalette(primary: Color(red: result.upper.x, green: result.upper.y, blue: result.upper.z),
                                            secondary: Color(red: result.lower.x, green: result.lower.y, blue: result.lower.z))
        } else {
            BopifyLog.playback.debug("artwork unavailable")
        }
        recent.append(url)
        while recent.count > 112 {
            let old = recent.removeFirst()
            images[old] = nil
            palettes[old] = nil
        }
    }

    func clear() {
        generation += 1
        pending.values.forEach { $0.cancel() }
        pending.removeAll()
        images.removeAll()
        palettes.removeAll()
        recent.removeAll()
    }
}

private nonisolated struct DecodedArtwork: Sendable {
    let image: CGImage
    let upper: SIMD3<Double>
    let lower: SIMD3<Double>
}

private actor ArtworkDecoder {
    private let context = CIContext(options: [.cacheIntermediates: false])

    func decode(_ data: Data) -> DecodedArtwork? {
        guard !Task.isCancelled,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 640
              ] as CFDictionary) else { return nil }
        let input = CIImage(cgImage: image)
        let extent = input.extent
        func average(_ rect: CGRect) -> SIMD3<Double> {
            let filter = CIFilter.areaAverage()
            filter.inputImage = input
            filter.extent = rect
            guard let output = filter.outputImage else { return SIMD3(repeating: 0.12) }
            var pixel = [UInt8](repeating: 0, count: 4)
            context.render(output, toBitmap: &pixel, rowBytes: 4,
                           bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8,
                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            let rgb = SIMD3(Double(pixel[0]), Double(pixel[1]), Double(pixel[2])) / 255
            let neutral = (rgb.x + rgb.y + rgb.z) / 3
            return (rgb * 0.8 + SIMD3(repeating: neutral * 0.2)) * 0.85
        }
        return DecodedArtwork(image: image,
            upper: average(CGRect(x: 0, y: extent.midY, width: extent.width, height: extent.height / 2)),
            lower: average(CGRect(x: 0, y: 0, width: extent.width, height: extent.height / 2)))
    }
}
