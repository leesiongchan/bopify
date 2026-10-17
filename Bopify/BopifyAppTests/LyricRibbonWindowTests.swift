#if DEBUG
import AppKit
import Testing

@MainActor @Suite("Lyric ribbon window", .serialized)
struct LyricRibbonWindowTests {
    @Test func passivePanelOnlyAllowsExplicitKeyboardInteraction() throws {
        let suite = "lyric-window-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = LyricRibbonModel(snapshot: lyricTestSnapshot())
        let controller = LyricRibbonWindowController(model: model, defaults: defaults, onHide: {})
        defer { controller.hide(); controller.panel.close() }
        #expect(!controller.panel.canBecomeKey)
        let host = try #require(controller.panel.contentView?.subviews.first)
        #expect(host.acceptsFirstMouse(for: nil))
        controller.focusForReading()
        #expect(controller.panel.canBecomeKey)
        #expect(model.isKeyboardInteracting)
        model.completeLoad(.timed(try lyricTestDocument()), token: model.beginLoad())
        model.holdText()
        controller.hide()
        #expect(!model.isVisible && !model.isHeld)
        #expect(!controller.panel.canBecomeKey)
        #expect(!model.isKeyboardInteracting)
    }

    @Test func missingDisplayAndSmallFrameKeepPanelReachable() {
        let screen = CGRect(x: -320, y: 100, width: 320, height: 480)
        let restored = LyricRibbonWindowController.reachableFrame(saved: CGRect(x: 5000, y: -900, width: 448, height: 157),
            size: CGSize(width: 448, height: 600), screens: [screen], preferred: screen)
        #expect(restored == screen)
        let malformed = LyricRibbonWindowController.reachableFrame(saved: CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1),
            size: CGSize(width: 250, height: 157), screens: [screen], preferred: screen)
        #expect(screen.contains(malformed))
    }

    @Test func savedLocationRemainsOnItsConnectedDisplay() {
        let left = CGRect(x: -1000, y: 0, width: 1000, height: 700)
        let right = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let saved = CGRect(x: -800, y: 100, width: 448, height: 157)
        let frame = LyricRibbonWindowController.reachableFrame(saved: saved, size: saved.size,
            screens: [left, right], preferred: right)
        #expect(frame == saved)
    }

    @Test func explicitKeyboardLoopReachesReadingAndHide() throws {
        let suite = "lyric-keyboard-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = LyricRibbonModel(snapshot: lyricTestSnapshot())
        var hideRequested = false
        let controller = LyricRibbonWindowController(model: model, defaults: defaults, onHide: { hideRequested = true })
        defer { controller.hide(); controller.panel.close() }
        controller.show()
        model.completeLoad(.timed(try lyricTestDocument()), token: model.beginLoad())
        controller.focusForReading()
        #expect(model.keyboardSelection == .reading)
        func key(_ code: UInt16) throws {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: controller.panel.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: code))
            controller.panel.keyDown(with: event)
        }
        try key(48)
        #expect(model.keyboardSelection == .hide)
        try key(48)
        #expect(model.keyboardSelection == .reading)
        try key(49)
        #expect(model.isHeld)
        try key(48)
        try key(36)
        #expect(hideRequested)
    }

    @Test func greatestOverlapDeterminesTheDestinationDisplay() {
        let tall = CGRect(x: -1000, y: 0, width: 1000, height: 1200)
        let short = CGRect(x: 0, y: 0, width: 1000, height: 480)
        let moved = CGRect(x: -40, y: 20, width: 448, height: 400)
        let frame = LyricRibbonWindowController.reachableFrame(saved: moved, size: moved.size,
            screens: [tall, short], preferred: tall)
        #expect(short.contains(frame))
    }

    @Test func draggingLongPassageToShortDisplayRemeasuresTheViewport() throws {
        let tall = CGRect(x: -1000, y: 0, width: 1000, height: 1200)
        let short = CGRect(x: 0, y: 0, width: 1000, height: 480)
        let content = LyricContent.timed(try LyricDocument(cues: [
            LyricCue(id: "long", startMs: 0, text: String(repeating: "A little room for the rain.\n", count: 100)),
        ]))
        let original = LyricRibbonWindowController.placement(content: content,
            saved: CGRect(x: -900, y: 20, width: 448, height: 157), textScale: 1, screens: [tall, short], preferred: tall)
        let destination = LyricRibbonWindowController.placement(content: content,
            saved: CGRect(x: 50, y: 20, width: 448, height: original.layout.panelSize.height),
            textScale: 1, screens: [tall, short], preferred: tall)
        #expect(original.layout.panelSize.height > 480)
        #expect(destination.layout.panelSize.height <= 440)
        #expect(destination.layout.textViewportHeight < original.layout.textViewportHeight)
        #expect(short.contains(destination.frame))
    }

    @Test func screenChangeNotificationRefreshesVisibleLayout() throws {
        let suite = "lyric-screen-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = LyricRibbonModel(snapshot: lyricTestSnapshot())
        let controller = LyricRibbonWindowController(model: model, defaults: defaults, onHide: {})
        defer { controller.hide(); controller.panel.close() }
        controller.show()
        let shortHeight = controller.panel.frame.height
        model.completeLoad(.plain(String(repeating: "A long passage with room to read.\n", count: 100)), token: model.beginLoad())
        controller.windowDidChangeScreen(Notification(name: NSWindow.didChangeScreenNotification, object: controller.panel))
        #expect(controller.panel.frame.height > shortHeight)
    }
}
#endif
