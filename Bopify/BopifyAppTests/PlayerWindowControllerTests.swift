import AppKit
import Testing
import SwiftUI
import BopifyPlayback

@MainActor @Suite("Player window", .serialized)
struct PlayerWindowControllerTests {
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
