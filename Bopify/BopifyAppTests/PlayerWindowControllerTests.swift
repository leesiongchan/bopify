import AppKit
import Testing
import SwiftUI
import BopifyPlayback

@MainActor @Suite("Player window", .serialized)
struct PlayerWindowControllerTests {
    @Test func hidingAnOnboardingTransferDiscardsQueuedAttentionWithoutLeavingAnEnvelope() throws {
        _ = NSApplication.shared
        let defaults = try #require(UserDefaults(suiteName: "onboarding-hide-\(UUID())"))
        let panel = StatusPanel(content: EmptyView())
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        panel.setFrame(CGRect(x: 80, y: 40, width: 410, height: 560), display: false)
        panel.orderFrontRegardless()
        let controller = PlayerWindowController(defaults: defaults)
        controller.attach(to: panel, onboardingRecordFrame: CGRect(x: 150, y: 70, width: 110, height: 108))
        controller.apply(mode: .expanded)
        controller.apply(mode: .compact)
        controller.hide()
        #expect(!panel.isVisible && !controller.isTransitioning && controller.onboardingHandoff == nil)
        #expect(controller.contentOffset == .zero, "Hiding must commit the final bounds before discarding the transition")
        #expect(panel.frame.size == controller.layout.contentSize)
    }

    @Test func theLatestAttentionRequestReplacesAnObsoleteQueuedMode() throws {
        _ = NSApplication.shared
        let defaults = try #require(UserDefaults(suiteName: "onboarding-attention-\(UUID())"))
        let panel = StatusPanel(content: EmptyView())
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        panel.setFrame(CGRect(x: 80, y: 40, width: 410, height: 560), display: false)
        panel.orderFrontRegardless()
        let controller = PlayerWindowController(defaults: defaults)
        controller.attach(to: panel, onboardingRecordFrame: CGRect(x: 150, y: 70, width: 110, height: 108))
        controller.apply(mode: .expanded)
        let expected = controller.layout
        controller.apply(mode: .compact)
        controller.apply(mode: .expanded)
        controller.finishTransition(controller.transitionID)
        #expect(controller.layout == expected && !controller.isTransitioning)
        #expect(controller.contentOffset == .zero)
    }

    @Test func onboardingTransfersBetweenMeasuredAndClampedRecordBounds() throws {
        _ = NSApplication.shared
        let defaults = try #require(UserDefaults(suiteName: "onboarding-bounds-\(UUID())"))
        let panel = StatusPanel(content: EmptyView())
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let initial = CGRect(x: 80, y: 40, width: 410, height: 560)
        panel.setFrame(initial, display: false)
        panel.orderFrontRegardless()
        let source = CGRect(x: 150, y: 70, width: 110, height: 108)
        let controller = PlayerWindowController(defaults: defaults)
        controller.attach(to: panel, onboardingRecordFrame: source)
        controller.apply(mode: .expanded,
                         visibleFrame: CGRect(x: 0, y: 0, width: 560, height: 700))
        let transfer = try #require(controller.onboardingHandoff)
        let expectedSource = source.offsetBy(dx: initial.minX - panel.frame.minX, dy: panel.frame.maxY - initial.maxY)
        #expect(transfer.recordFrame(at: 0) == expectedSource)
        #expect(transfer.recordFrame(at: 0.16) == expectedSource, "The pocket recedes before the disc moves")
        let target = transfer.recordFrame(at: 1)
        #expect(target.width == controller.layout.recordDiameter && target.width == target.height)
        #expect(target.midX == controller.contentOffset.x + controller.layout.recordCenter.x)
        #expect(target.midY == controller.contentOffset.y + controller.layout.recordCenter.y)
        let targetOnScreen = CGPoint(x: panel.frame.minX + target.midX, y: panel.frame.maxY - target.midY)
        controller.finishTransition(controller.transitionID)
        let finalOnScreen = CGPoint(x: panel.frame.minX + controller.layout.recordCenter.x,
                                   y: panel.frame.maxY - controller.layout.recordCenter.y)
        #expect(finalOnScreen == targetOnScreen, "Committing the native frame must not move the settled record")
        #expect(controller.onboardingHandoff == nil)
    }

    @Test func theIncomingRecordAppearsOnlyAfterTheSharedRecordHasArrived() {
        let geometry = OnboardingHandoffGeometry(id: UUID(), source: CGRect(x: 80, y: 40, width: 110, height: 108),
            destination: CGRect(x: 10, y: 10, width: 182, height: 182))
        for progress: CGFloat in [0, 0.15, 0.29, 0.30, 0.5, 0.79, 0.83, 0.9, 1] {
            let visuals = OnboardingHandoffVisuals(progress: progress)
            #expect(visuals.sourceRecordOpacity == 0 || visuals.transferOpacity == 0)
            if visuals.playerRecordOpacity > 0 {
                #expect(geometry.recordFrame(at: progress) == geometry.destination)
            }
        }

    }

    @Test func onboardingKeepsItsPrecomputedDestinationUntilTheRecordArrives() throws {
        _ = NSApplication.shared
        let defaults = try #require(UserDefaults(suiteName: "onboarding-destination-\(UUID())"))
        let panel = StatusPanel(content: EmptyView())
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        panel.setFrame(CGRect(x: 80, y: 40, width: 410, height: 560), display: false)
        panel.orderFrontRegardless()
        let controller = PlayerWindowController(defaults: defaults)
        controller.attach(to: panel, onboardingRecordFrame: CGRect(x: 150, y: 70, width: 110, height: 108))
        controller.apply(mode: .expanded,
                         visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900))
        let transition = controller.transitionID
        let destination = controller.layout
        controller.apply(mode: .compact,
                         visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900))
        #expect(controller.transitionID == transition && controller.layout == destination,
                "Attention changes must not retarget the record halfway through setup's handoff")
        controller.invalidateTransition()
    }

    @Test func onboardingHandoffAnchorsThePlayerAtTheVisibleStartupRecord() throws {
        _ = NSApplication.shared
        let suite = "onboarding-anchor-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("{900, 700}", forKey: "player.recordCenter")
        let panel = StatusPanel(content: EmptyView())
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        panel.setFrame(CGRect(x: 80, y: 40, width: 410, height: 560), display: false)
        let record = CGRect(x: 150, y: 70, width: 110, height: 110)
        let expected = CGPoint(x: panel.frame.minX + record.midX, y: panel.frame.maxY - record.midY)
        let controller = PlayerWindowController(defaults: defaults)
        controller.attach(to: panel, onboardingRecordFrame: record)
        #expect(controller.layout.recordCenter.x + controller.contentOffset.x == record.midX)
        #expect(controller.layout.recordCenter.y + controller.contentOffset.y == record.midY)
        #expect(controller.layout.recordDiameter * controller.recordPresentationScale == record.width)
        controller.apply(mode: .compact, animated: false,
                         visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900))
        let actual = CGPoint(x: panel.frame.minX + controller.layout.recordCenter.x,
                             y: panel.frame.maxY - controller.layout.recordCenter.y)
        #expect(actual == expected, "Setup must settle around its visible record instead of jumping to a saved window position")
    }

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
        controller.apply(mode: .compact, animated: false, visibleFrame: screen, showsLyrics: true)
        let lyricTop = panel.frame.maxY - controller.layout.lyricsFrame.minY
        panel.orderFrontRegardless()
        controller.apply(mode: .expanded, visibleFrame: screen, showsLyrics: true)
        let obsolete = controller.transitionID
        controller.apply(mode: .compact, visibleFrame: screen, showsLyrics: true)
        controller.apply(mode: .expanded, visibleFrame: screen, showsLyrics: true)
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
        controller.apply(mode: .expanded, animated: false, visibleFrame: screen, showsLyrics: true)
        func lyricOrigin() -> CGPoint {
            CGPoint(x: panel.frame.minX + controller.layout.lyricsFrame.minX,
                    y: panel.frame.maxY - controller.layout.lyricsFrame.minY)
        }
        let origin = lyricOrigin()
        controller.apply(mode: .compact, animated: false, visibleFrame: screen, showsLyrics: true)
        #expect(lyricOrigin() == origin)
        #expect(screen.contains(panel.frame))
        controller.apply(mode: .expanded, animated: false, visibleFrame: screen, showsLyrics: true)
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
        controller.apply(mode: .compact, animated: false, visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900), showsLyrics: true)
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
        controller.apply(mode: mode, animated: false)
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
        controller.apply(mode: .compact, animated: false, visibleFrame: visible)

        controller.apply(mode: mode, animated: false, visibleFrame: visible)

        #expect(panel.frame.size == CGSize(width: 484, height: 360))
        #expect(controller.layout == recordLayout(mode: mode, availableSize: visible.size))
        #expect(visible.contains(panel.frame))
    }
}
