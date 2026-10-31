import AppKit
import Testing
import SwiftUI
import BopifyPlayback

@MainActor @Suite("Player window", .serialized)
struct PlayerWindowControllerTests {
    @Test func onboardingFloatsWithoutChangingTheSavedWindowPreference() async throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: "player.keepOnTop")
        defer {
            if let saved { defaults.set(saved, forKey: "player.keepOnTop") }
            else { defaults.removeObject(forKey: "player.keepOnTop") }
        }
        defaults.set(false, forKey: "player.keepOnTop")
        let existingWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let environment = makePreviewEnvironment(.nothingPlaying)
        defer { environment.player?.stop() }
        let controller = StatusItemController(content: EmptyView(), environment: environment)
        let panel = try #require(NSApp.windows.compactMap { $0 as? StatusPanel }
            .first { !existingWindows.contains(ObjectIdentifier($0)) })
        panel.isReleasedWhenClosed = false
        defer { panel.orderOut(nil); panel.close() }
        controller.togglePlayer()
        #expect(panel.isVisible)
        #expect(panel.level == .normal)

        await environment.requireLibrarySetup()
        // Presentation observation applies window changes on the next main-actor turn.
        for _ in 0..<10 { await Task.yield() }

        #expect(panel.level == .floating)
        #expect(!environment.presentation.keepOnTop)
        #expect(!defaults.bool(forKey: "player.keepOnTop"))
    }

    @Test(arguments: [false, true])
    func fullscreenEligibilityFollowsActualFocusWithoutChangingDesktopLevel(floating: Bool) throws {
        _ = NSApplication.shared
        let panel = StatusPanel(content: EmptyView())
        panel.isReleasedWhenClosed = false
        defer { panel.orderOut(nil); panel.close() }
        let level: NSWindow.Level = floating ? .floating : .normal
        panel.level = level
        panel.orderFrontRegardless()
        #expect(!panel.isKeyWindow)
        #expect(!panel.collectionBehavior.contains(.fullScreenAuxiliary))

        panel.makeKeyAndOrderFront(nil)
        #expect(panel.isKeyWindow)
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        let other = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 200, height: 100),
                             styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        other.makeKeyAndOrderFront(nil)
        #expect(!panel.isKeyWindow)
        #expect(!panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(panel.level == level)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))

        var playerFocus: Bool?
        panel.onKeyChanged = { playerFocus = $0 }
        panel.focusLyrics(keepingPlayerExpanded: false)
        #expect(panel.isKeyWindow)
        #expect(playerFocus == false)
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        panel.orderOut(nil)
        #expect(!panel.collectionBehavior.contains(.fullScreenAuxiliary))
        panel.orderFrontRegardless()
        #expect(!panel.collectionBehavior.contains(.fullScreenAuxiliary))
        panel.focusPlayer()
        #expect(panel.isKeyWindow)
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
    }

    @Test func interruptedLyricTransitionsKeepTheNewestFrameAndAnchor() throws {
        _ = NSApplication.shared
        let suite = "lyrics-interrupt-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let panel = StatusPanel(content: EmptyView())
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        // Stay low: once visible, AppKit clamps the transition envelope to the real display, which is small on CI.
        panel.setFrame(CGRect(x: 400, y: 100, width: 484, height: 158), display: false)
        let controller = PlayerWindowController(defaults: defaults)
        controller.attach(to: panel)
        controller.apply(mode: .compact, reduceMotion: true, visibleFrame: screen, showsLyrics: true)
        let lyricTop = panel.frame.maxY - controller.layout.lyricsFrame.minY
        panel.orderFrontRegardless()
        controller.apply(mode: .expanded, reduceMotion: false, visibleFrame: screen, showsLyrics: true)
        let obsolete = controller.transitionID
        controller.apply(mode: .compact, reduceMotion: false, visibleFrame: screen, showsLyrics: true)
        controller.apply(mode: .expanded, reduceMotion: false, visibleFrame: screen, showsLyrics: true)
        controller.finishTransition(obsolete)
        #expect(controller.isTransitioning)
        controller.finishTransition(controller.transitionID)
        #expect(!controller.isTransitioning)
        #expect(panel.frame.size == controller.layout.contentSize)
        #expect(panel.frame.maxY - controller.layout.lyricsFrame.minY == lyricTop)
    }

    @Test func lyricsKeepTheirScreenPositionAcrossCollapseAndExpansion() throws {
        _ = NSApplication.shared
        let defaults = try #require(UserDefaults(suiteName: "lyrics-anchor-\(UUID().uuidString)"))
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let panel = StatusPanel(content: EmptyView())
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        panel.setFrame(CGRect(x: 400, y: 500, width: 142, height: 142), display: false)
        let controller = PlayerWindowController(defaults: defaults)
        controller.attach(to: panel)
        controller.apply(mode: .expanded, reduceMotion: true, visibleFrame: screen, showsLyrics: true)
        func lyricOrigin() -> CGPoint {
            CGPoint(x: panel.frame.minX + controller.layout.lyricsFrame.minX,
                    y: panel.frame.maxY - controller.layout.lyricsFrame.minY)
        }
        let origin = lyricOrigin()
        controller.apply(mode: .compact, reduceMotion: true, visibleFrame: screen, showsLyrics: true)
        #expect(lyricOrigin() == origin)
        #expect(screen.contains(panel.frame))
        controller.apply(mode: .expanded, reduceMotion: true, visibleFrame: screen, showsLyrics: true)
        #expect(lyricOrigin() == origin)
    }

    @Test func theCompactVinylIsAPassiveClickAndDragTarget() throws {
        _ = NSApplication.shared
        let defaults = try #require(UserDefaults(suiteName: "lyrics-hover-\(UUID().uuidString)"))
        let panel = StatusPanel(content: EmptyView())
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let controller = PlayerWindowController(defaults: defaults)
        controller.attach(to: panel)
        controller.apply(mode: .compact, reduceMotion: true, visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900), showsLyrics: true)
        #expect(panel.containsPlayerPoint?(controller.layout.recordCenter) == false)
        let recordEdge = CGPoint(x: controller.layout.recordCenter.x + controller.layout.recordDiameter / 2 - 3,
                                 y: controller.layout.recordCenter.y)
        #expect(panel.containsPlayerPoint?(recordEdge) == false)
        #expect(panel.containsLyricsPoint?(recordEdge) == true)
        let lyric = controller.layout.lyricsFrame
        let point = CGPoint(x: lyric.midX, y: lyric.midY)
        #expect(panel.containsPlayerPoint?(point) == false)
        #expect(panel.containsLyricsPoint?(point) == true)
    }

    @Test func menuBarClickRaisesTheVisiblePlayerAfterAnotherWindowTakesFocus() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let keys = ["player.frame", "player.keepOnTop"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        let existingWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let environment = makePreviewEnvironment(.nothingPlaying)
        defer { environment.player?.stop() }
        let controller = StatusItemController(content: EmptyView(), environment: environment)
        let panel = try #require(NSApp.windows.compactMap { $0 as? StatusPanel }
            .first { !existingWindows.contains(ObjectIdentifier($0)) })
        panel.isReleasedWhenClosed = false
        defer { panel.orderOut(nil); panel.close() }
        let click = NSSelectorFromString("statusItemClicked:")
        controller.perform(click, with: nil)
        #expect(panel.isVisible && panel.isKeyWindow)
        let other = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 200, height: 100),
                             styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        other.makeKeyAndOrderFront(nil)
        #expect(panel.isVisible && !panel.isKeyWindow)

        controller.perform(click, with: nil)

        #expect(panel.isVisible && panel.isKeyWindow)
        controller.perform(click, with: nil)
        #expect(!panel.isVisible)
    }

    @Test(arguments: [PlayerMode.expanded, .queue])
    func draggingNearBottomKeepsPlayerSize(mode: PlayerMode) throws {
        let suite = "player-bottom-drag-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let visible = try #require(NSScreen.main?.visibleFrame)
        let panel = StatusPanel(content: EmptyView())
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let controller = PlayerWindowController(defaults: defaults)
        controller.attach(to: panel)
        panel.setFrameOrigin(CGPoint(x: visible.midX - 205, y: visible.midY))
        controller.apply(mode: mode, reduceMotion: true)
        let originalSize = panel.frame.size
        let originalLayout = controller.layout

        controller.setDragging(true)
        panel.setFrameOrigin(CGPoint(x: panel.frame.minX, y: visible.minY - 100))
        controller.setDragging(false)

        #expect(panel.frame.size == originalSize)
        #expect(controller.layout == originalLayout)
        #expect(visible.contains(panel.frame))
    }

    @Test(arguments: [PlayerMode.expanded, .queue])
    func expandingNearBottomUsesTheFullPlayerSize(mode: PlayerMode) throws {
        let suite = "player-bottom-expand-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let panel = StatusPanel(content: EmptyView())
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        panel.setFrame(CGRect(x: 600, y: 0, width: 142, height: 142), display: false)
        let controller = PlayerWindowController(defaults: defaults)
        controller.attach(to: panel)
        controller.apply(mode: .compact, reduceMotion: true, visibleFrame: visible)

        controller.apply(mode: mode, reduceMotion: true, visibleFrame: visible)

        #expect(panel.frame.size == CGSize(width: 484, height: 360))
        #expect(controller.layout == recordLayout(mode: mode, availableSize: visible.size))
        #expect(visible.contains(panel.frame))
    }
}
