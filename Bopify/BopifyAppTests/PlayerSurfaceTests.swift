import AppKit
import SwiftUI
import Testing

@MainActor @Suite("Player surface", .serialized,
    .enabled("Artwork is hidden when transparency is reduced or contrast is increased") { @MainActor in
        !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            && !NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    })
struct PlayerSurfaceTests {
    @Test func artworkLetsTheBackdropShowThrough() async throws {
        let artwork = image(.red)
        func content(_ backdrop: Color) -> some View {
            PlayerSurface(artwork: artwork) { Color.clear }
                .frame(width: 160, height: 160)
                .background(backdrop)
                .environment(\.colorScheme, .dark)
        }
        let host = NSHostingView(rootView: content(.black))
        let window = window(host)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        let dark = try pixel(host)
        host.rootView = content(.white)
        try await Task.sleep(for: .milliseconds(150))
        let light = try pixel(host)
        #expect(light.greenComponent - dark.greenComponent > 0.15,
                "Artwork must transmit the backdrop instead of covering it with an opaque image")
    }

    @Test func changingArtworkBlendsOldAndNewColors() async throws {
        func content(_ artwork: Image) -> some View {
            PlayerSurface(artwork: artwork) { Color.clear }
                .frame(width: 160, height: 160)
                .background(.black)
                .environment(\.colorScheme, .dark)
        }
        let host = NSHostingView(rootView: content(image(.red)))
        let window = window(host)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        host.rootView = content(image(.blue))
        try await Task.sleep(for: blendSampleDelay)
        let blended = try pixel(host)
        #expect(blended.redComponent > 0.03 && blended.blueComponent > 0.03,
                "A song change must blend both covers instead of replacing the background immediately")
        try await Task.sleep(for: .milliseconds(650))
        let settled = try pixel(host)
        #expect(settled.blueComponent > settled.redComponent + 0.1)
    }

    @Test func rapidSongChangesContinueFromTheVisibleBlend() async throws {
        func content(_ artwork: Image) -> some View {
            PlayerSurface(artwork: artwork) { Color.clear }
                .frame(width: 160, height: 160)
                .background(.black)
                .environment(\.colorScheme, .dark)
        }
        let host = NSHostingView(rootView: content(image(.red)))
        let window = window(host)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(800))
        host.rootView = content(image(.blue))
        try await Task.sleep(for: blendSampleDelay)
        let beforeSkip = try pixel(host)
        host.rootView = content(image(.green))
        try await Task.sleep(for: .milliseconds(30))
        let afterSkip = try pixel(host)
        #expect(abs(afterSkip.redComponent - beforeSkip.redComponent) < 0.12)
        #expect(abs(afterSkip.blueComponent - beforeSkip.blueComponent) < 0.12)
        try await Task.sleep(for: .milliseconds(800))
        let settled = try pixel(host)
        #expect(settled.greenComponent > settled.redComponent + 0.1)
        #expect(settled.greenComponent > settled.blueComponent + 0.1)
    }

    private func image(_ color: Color) -> Image {
        Image(nsImage: ImageRenderer(content: color.frame(width: 32, height: 32)).nsImage!)
    }

    private var blendSampleDelay: Duration {
        .milliseconds(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 60 : 250)
    }

    private func window<Content: View>(_ host: NSHostingView<Content>) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 300, y: 300, width: 160, height: 160),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func pixel(_ view: NSView) throws -> NSColor {
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
    }
}
