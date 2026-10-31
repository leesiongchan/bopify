import AppKit
import SwiftUI
import Testing
import BopifyDomain
import BopifyLibrary
import BopifyPlayback
import ImageIO
import UniformTypeIdentifiers

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
        var launches: [CoverFlowLaunch] = []
        let content = LibraryShelf(environment: environment, artworkStore: environment.artworkStore,
            tabsInset: 0, coverBleed: 0, onPlay: { requests.append($0); launches.append($1) })
            .defaultAppStorage(defaults)
            .frame(width: 332, height: 160)
            .coordinateSpace(name: CoverFlowLaunch.coordinateSpace)
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
        #expect(launches.isEmpty)
        try await waitUntil { input.input?.isAnimating == true }
        // Drive the spring directly: hostless tests cannot rely on display-link delivery.
        for _ in 0..<120 where input.input?.isAnimating == true {
            input.input?.onFrame(1.0 / 60)
            await Task.yield()
        }
        try #require(input.input?.isAnimating == false)
        try click(input, x: input.bounds.midX)
        #expect(requests.count == 1)
        #expect(requests.first?.contextURI == next)
        let launch = try #require(launches.first)
        #expect(launch.itemURI == next)
        #expect(launch.sourceFrame.width > 60 && launch.sourceFrame.width < 90)
        #expect(abs(launch.sourceFrame.midX - 166) < 2)
        #expect(launch.artwork != nil)
    }

    @Test func selectedCoverLoadsDuringTheFlightAndProducesAMotionPreview() async throws {
        let environment = makePreviewEnvironment(.paused)
        let player = try #require(environment.player)
        defer { player.stop() }
        environment.presentation.sendAttention(.visibility(true))
        environment.presentation.sendAttention(.keyboardFocus(true))
        let suite = "\(NSTemporaryDirectory())bopify-flight-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("liked", forKey: "library.tab")
        let controller = PlayerWindowController(defaults: defaults)
        let content = RecordPlayerView(player: player, artworkStore: environment.artworkStore,
                                      presentation: environment.presentation, windowController: controller)
            .environment(environment).defaultAppStorage(defaults)
        let panel = StatusPanel(content: content)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        controller.attach(to: panel)
        controller.apply(mode: .expanded, reduceMotion: true,
                         visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        panel.makeKeyAndOrderFront(nil)
        try await waitUntil { coverInput(in: panel.contentView)?.input != nil && !environment.likedSongs.tracks.isEmpty }
        try await Task.sleep(for: .milliseconds(200))
        let input = try #require(coverInput(in: panel.contentView))
        let host = try #require(panel.contentView)
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bopify-turntable-prototype.gif")
        let gif = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 48, nil))
        CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        var previousFrame = Date.now
        var outgoingDiscAlpha: CGFloat = 0
        for frame in 0..<48 {
            if frame == 5 { try click(input, x: input.bounds.midX) }
            if frame == 14 {
                #expect(player.state.currentTrack?.uri == environment.likedSongs.tracks.first?.uri)
                #expect(player.state.phase == .playing)
            }
            if frame == 28 || frame == 40 { player.togglePlayPause() }
            if frame == 9 {
                try String(panel.windowNumber).write(to: URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("bopify-transition-window-id.txt"), atomically: true, encoding: .utf8)
                try await Task.sleep(for: .milliseconds(500))
            }
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let image = try #require(bitmap.cgImage)
            if frame == 0 || frame == 8 {
                let point = CGPoint(x: controller.layout.recordCenter.x - controller.layout.recordDiameter * 0.4,
                                    y: controller.layout.recordCenter.y)
                let sample = try #require(bitmap.colorAt(x: Int(point.x * CGFloat(bitmap.pixelsWide) / host.bounds.width),
                    y: Int(point.y * CGFloat(bitmap.pixelsHigh) / host.bounds.height)))
                if frame == 0 { outgoingDiscAlpha = sample.alphaComponent }
                else {
                    #expect(outgoingDiscAlpha > 0.8)
                    #expect(sample.alphaComponent > outgoingDiscAlpha * 0.95,
                            "The outgoing vinyl must remain visible while the incoming cover is being drawn in")
                }
            }
            let delay = max(1.0 / 30, Date.now.timeIntervalSince(previousFrame))
            previousFrame = .now
            CGImageDestinationAddImage(gif, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
            if frame == 0 || frame == 9 {
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: url.deletingLastPathComponent().appendingPathComponent("bopify-turntable-\(frame == 0 ? "before" : "flight").png"))
            }
            try await Task.sleep(for: .milliseconds(33))
        }
        #expect(CGImageDestinationFinalize(gif))
    }

    @Test(arguments: [484.0, 350.0])
    func controlsOnlyBounceWhenContentOverflows(width: CGFloat) async throws {
        let environment = makePreviewEnvironment(.paused)
        defer { environment.player?.stop() }
        let presentation = environment.presentation
        presentation.sendAttention(.visibility(true))
        presentation.sendAttention(.keyboardFocus(true))
        let suite = "\(NSTemporaryDirectory())bopify-controls-bounce-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = PlayerWindowController(defaults: defaults)
        let content = RecordPlayerView(player: try #require(environment.player), artworkStore: environment.artworkStore,
                                      presentation: presentation, windowController: controller)
            .environment(environment).frame(width: width, height: 360)
        let panel = StatusPanel(content: content)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        controller.attach(to: panel)
        controller.apply(mode: .expanded, reduceMotion: true, visibleFrame: CGRect(x: 0, y: 0, width: width, height: 360))
        panel.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(200))
        panel.contentView?.layoutSubtreeIfNeeded()
        let scroll = try #require(scrollViews(in: panel.contentView).first {
            abs($0.frame.width - controller.layout.controlsFrame.width) < 1
        })
        #expect(scroll.verticalScrollElasticity == .none)
        #expect(scroll.horizontalScroller?.isHidden != false)
        #expect(scroll.verticalScroller?.isHidden != false)
        if width == 484 {
            #expect(scroll.horizontalScrollElasticity == .none)
            #expect((scroll.documentView?.frame.height ?? 0) <= scroll.contentView.bounds.height + 1)
        } else {
            #expect((scroll.documentView?.frame.width ?? 0) >= 192)
            #expect((scroll.documentView?.frame.width ?? 0) > scroll.contentView.bounds.width)
        }
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
