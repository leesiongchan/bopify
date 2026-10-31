import AppKit
import Observation
import SwiftUI
import Testing
import BopifyDomain
import BopifyLibrary

@MainActor @Suite("Cover Flow layering", .serialized)
struct CoverFlowLayeringTests {
    @Test func middleCoverOccludesBothNeighborsBeforeAndDuringActivation() async throws {
        let source = OverlapSource()
        let colors: [Color] = [.green, .red, .blue]
        let images = Dictionary(uniqueKeysWithValues: source.items.enumerated().map { index, track in
            (track.artwork!.url, ImageRenderer(content: colors[index].frame(width: 160, height: 160)).nsImage!)
        })
        let store = ArtworkStore(previewImages: images)
        let content = CoverFlowView(model: source, copy: .liked, artworkStore: store, onPlay: { _, _ in })
            .frame(width: 240, height: 160).background(.black)
            .coordinateSpace(name: CoverFlowLaunch.coordinateSpace)
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: CGRect(x: 300, y: 300, width: 240, height: 160),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(300))

        for activated in [false, true] {
            if activated {
                let input = try #require(inputView(in: host)?.input)
                input.onPlay()
                try await Task.sleep(for: .milliseconds(200))
            }
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            for x in [89, 151] {
                let color = try #require(bitmap.colorAt(x: x * bitmap.pixelsWide / 240,
                    y: 44 * bitmap.pixelsHigh / 160)?.usingColorSpace(.deviceRGB))
                #expect(color.redComponent > color.greenComponent + 0.08,
                        "The left cover must remain behind the middle cover; activated=\(activated)")
                #expect(color.redComponent > color.blueComponent + 0.08,
                        "The right cover must remain behind the middle cover; activated=\(activated)")
            }
            let left = try #require(bitmap.colorAt(x: 74 * bitmap.pixelsWide / 240,
                y: 44 * bitmap.pixelsHigh / 160)?.usingColorSpace(.deviceRGB))
            let right = try #require(bitmap.colorAt(x: 172 * bitmap.pixelsWide / 240,
                y: 44 * bitmap.pixelsHigh / 160)?.usingColorSpace(.deviceRGB))
            #expect(left.greenComponent > left.redComponent + 0.2, "The left neighboring cover must be rendered")
            #expect(right.blueComponent > right.redComponent + 0.2, "The right neighboring cover must be rendered")
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("bopify-cover-overlap-\(activated).png"))
        }
    }

    private func inputView(in view: NSView) -> CoverFlowInput.InputView? {
        (view as? CoverFlowInput.InputView) ?? view.subviews.lazy.compactMap { inputView(in: $0) }.first
    }
}

@MainActor @Observable private final class OverlapSource: CoverFlowSource {
    let items: [Track] = (0..<3).map {
        Track(uri: SpotifyURI("spotify:track:overlap\($0)")!, title: "Cover \($0)", artists: [], albumTitle: nil,
              artwork: Artwork(url: previewArtworkURL($0)), durationMs: 1000)
    }
    var selectedURI = SpotifyURI("spotify:track:overlap1")
    var isLoading: Bool { false }
    var error: LibraryError? { nil }
    var retryAfter: Date? { nil }
    var hasMore: Bool { false }
    func select(_ uri: SpotifyURI) { selectedURI = uri }
    func reveal(at date: Date) async {}
    func hide(at date: Date) {}
    func loadMore() async {}
    func loadMoreIfNeeded(near uri: SpotifyURI) async {}
    func retry(at date: Date) async {}
}
