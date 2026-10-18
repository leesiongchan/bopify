import AppKit
import SwiftUI
import Testing
import BopifyPlayback

@MainActor @Suite("Library and search layout", .serialized)
struct LibrarySearchLayoutTests {
    @Test func narrowPlayerCanScrollToEveryControl() async throws {
        let environment = makePreviewEnvironment(.paused)
        defer { environment.player?.stop() }
        let presentation = environment.presentation
        presentation.sendAttention(.visibility(true))
        presentation.sendAttention(.keyboardFocus(true))
        let suite = "\(NSTemporaryDirectory())bopify-narrow-controls-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = PlayerWindowController(defaults: defaults)
        let content = RecordPlayerView(player: try #require(environment.player), artworkStore: environment.artworkStore,
                                      presentation: presentation, windowController: controller)
            .environment(environment).frame(width: 350, height: 360)
        let panel = StatusPanel(content: content)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        controller.attach(to: panel)
        controller.apply(mode: .expanded, reduceMotion: true, visibleFrame: CGRect(x: 0, y: 0, width: 350, height: 360))
        panel.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(200))
        panel.contentView?.layoutSubtreeIfNeeded()
        let scroll = try #require(scrollViews(in: panel.contentView).first { abs($0.frame.width - 176) < 1 })
        #expect((scroll.documentView?.frame.width ?? 0) >= 192)
    }

}

@MainActor private func scrollViews(in view: NSView?) -> [NSScrollView] {
    guard let view else { return [] }
    return (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
}
