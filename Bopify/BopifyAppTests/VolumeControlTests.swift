import AppKit
import Testing
import SwiftUI
import BopifyPlayback

@MainActor @Suite("Volume control", .serialized)
struct VolumeControlTests {
    @Test func horizontalSliderKeepsItsAccessibleLabelAndUpdatesVolume() throws {
        let engine = PreviewPlaybackEngine(tracks: previewTracks)
        let player = PlayerModel(engine: engine)
        player.applyPreviewEvents(engine.restoredSession(at: 0, positionMs: 0, playing: false))
        player.start()
        defer { player.stop() }
        var editingEnded = 0
        let host = NSHostingView(rootView: VolumePopoverContent(player: player,
            onEditingBegan: player.beginVolumeEditing, onEditingEnded: {
                editingEnded += 1
                player.endVolumeEditing()
            }))
        let window = NSWindow(contentRect: CGRect(x: 300, y: 300, width: 194, height: 48),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        func slider(in view: NSView) -> NSSlider? {
            if let slider = view as? NSSlider { return slider }
            return view.subviews.lazy.compactMap { slider(in: $0) }.first
        }
        let slider = try #require(slider(in: host))
        #expect(!slider.isVertical)
        #expect(slider.frame.width > slider.frame.height)
        #expect(slider.accessibilityLabel() == String(localized: "transport.volume"))
        slider.doubleValue = 0.8
        #expect(slider.sendAction(slider.action, to: slider.target))

        #expect(player.displayVolume == 0.8)
        #expect(editingEnded == 1)
    }
}
