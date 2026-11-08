import AppKit
import SwiftUI
import Testing
import BopifyPlayback
import BopifyDomain

@MainActor @Suite("Idle player", .serialized)
struct IdlePlayerRenderingTests {
    @Test func emptyMetadataInvitesLibraryPlaybackAndUpdatesWhileLoading() async throws {
        _ = NSApplication.shared
        let environment = makePreviewEnvironment(.nothingPlaying)
        let player = try #require(environment.player)
        let window = NSWindow(contentRect: CGRect(x: 300, y: 300, width: 300, height: 80),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); player.stop() }
        window.contentView = NSHostingView(rootView: PlayerTrackMetadata(track: nil, player: player,
            artworkStore: environment.artworkStore, presentation: environment.presentation)
            .frame(width: 300, height: 80).environment(\.accessibilityEnabled, true))
        window.makeKeyAndOrderFront(nil)
        let content = try #require(window.contentView)
        try await Task.sleep(for: .milliseconds(100))
        let title = try AppearanceTestAccessibility.element("player.trackTitle", in: content)
        #expect((title.value ?? title.object.accessibilityLabel?()) == SoloistResources.string("player.empty.title"))
        let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let capture = root.appendingPathComponent("build/test-artifacts/idle-player/metadata.png")
        try FileManager.default.createDirectory(at: capture.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: capture)
        player.applyPreviewEvents([.loading])
        try await Task.sleep(for: .milliseconds(80))
        let loading = try AppearanceTestAccessibility.element("player.trackTitle", in: content)
        #expect((loading.value ?? loading.object.accessibilityLabel?()) == SoloistResources.string("player.loading"))
    }
}
