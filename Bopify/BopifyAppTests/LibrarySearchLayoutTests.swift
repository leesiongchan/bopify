import AppKit
import SwiftUI
import Testing
import BopifyDomain
import BopifyLibrary
import BopifyPlayback

@MainActor @Suite("Library and search layout", .serialized)
struct LibrarySearchLayoutTests {
    @Test func librarySideCoverCentersBeforePlaying() async throws {
        let environment = makePreviewEnvironment(.paused)
        defer { environment.player?.stop() }
        let suite = "\(NSTemporaryDirectory())bopify-library-click-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("library", forKey: "library.tab")
        var requests: [PlayRequest] = []
        let content = LibraryShelf(environment: environment, artworkStore: environment.artworkStore,
            tabsInset: 0, coverBleed: 0, onPlay: { requests.append($0) })
            .defaultAppStorage(defaults)
            .frame(width: 332, height: 160)
        let panel = StatusPanel(content: content)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        panel.makeKeyAndOrderFront(nil)
        try await waitUntil { coverInput(in: panel.contentView)?.input != nil && environment.collections.items.count > 1 }
        let input = try #require(coverInput(in: panel.contentView))
        let next = environment.collections.items[1].uri
        try click(input, x: input.bounds.midX + 44)
        #expect(environment.collections.selectedURI == next)
        #expect(requests.isEmpty)
        try await waitUntil { input.input?.isAnimating == true }
        try await waitUntil { input.input?.isAnimating == false }
        try click(input, x: input.bounds.midX)
        #expect(requests.count == 1)
        #expect(requests.first?.contextURI == next)
    }

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
        #expect(scroll.horizontalScroller?.isHidden != false)
        #expect(scroll.verticalScroller?.isHidden != false)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }

    private func click(_ input: CoverFlowInput.InputView, x: CGFloat) throws {
        let window = try #require(input.window)
        let point = input.convert(CGPoint(x: x, y: input.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            window.sendEvent(event)
        }
    }
}

@MainActor private func coverInput(in view: NSView?) -> CoverFlowInput.InputView? {
    if let input = view as? CoverFlowInput.InputView { return input }
    return view?.subviews.lazy.compactMap { coverInput(in: $0) }.first
}

@MainActor private func scrollViews(in view: NSView?) -> [NSScrollView] {
    guard let view else { return [] }
    return (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
}
