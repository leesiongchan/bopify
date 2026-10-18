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
        model.beginReading()
        controller.hide()
        #expect(!model.isVisible && !model.isReading)
        #expect(!controller.panel.canBecomeKey)
        #expect(!model.isKeyboardInteracting)
    }

    @Test func nativeTextClickSeeksOnceWithoutTakingKeyboardFocus() async throws {
        let suite = "lyric-pointer-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = LyricRibbonModel(snapshot: lyricTestSnapshot())
        var targets: [Int64] = []
        let controller = LyricRibbonWindowController(model: model, defaults: defaults,
            onSeek: { time, _ in targets.append(time) }, onHide: {})
        defer { controller.hide(); controller.panel.close() }
        controller.show()
        model.completeLoad(.timed(try LyricDocument(cues: [
            LyricCue(id: "previous", startMs: 60_000, text: "Previous words"),
            LyricCue(id: "current", startMs: 70_000, text: "Current words"),
            LyricCue(id: "next", startMs: 80_000, text: "Upcoming words"),
        ])), token: model.beginLoad())
        controller.refreshLayout(textScale: 1)
        controller.panel.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        func passage(in view: NSView) -> LyricReadingTextView? {
            if let text = view as? LyricReadingTextView { return text }
            return view.subviews.lazy.compactMap { passage(in: $0) }.first
        }
        let reader = try #require(controller.panel.contentView.flatMap { passage(in: $0) })
        let manager = try #require(reader.layoutManager)
        let container = try #require(reader.textContainer)
        let range = (reader.string as NSString).range(of: "Current words")
        let glyph = manager.glyphIndexForCharacter(at: range.location)
        let box = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        let point = reader.convert(CGPoint(x: box.midX, y: box.midY), to: nil)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: controller.panel.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
            timestamp: down.timestamp + 0.1, windowNumber: controller.panel.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
        NSApp.postEvent(up, atStart: true)
        controller.panel.sendEvent(down)
        #expect(targets == [70_000])
        #expect(!controller.panel.canBecomeKey)
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

    @Test func explicitKeyboardReadingScrollsWithoutPlaybackCommandsAndEscapeHides() throws {
        let suite = "lyric-keyboard-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = LyricRibbonModel(snapshot: lyricTestSnapshot())
        var hideRequested = false
        let controller = LyricRibbonWindowController(model: model, defaults: defaults, onHide: { hideRequested = true })
        defer { controller.hide(); controller.panel.close() }
        controller.show()
        model.completeLoad(.timed(try lyricTestDocument()), token: model.beginLoad())
        controller.refreshLayout(textScale: 1)
        controller.panel.contentView?.layoutSubtreeIfNeeded()
        controller.focusForReading()
        let reader = try #require(controller.panel.firstResponder as? LyricReadingTextView)
        let original = model.snapshot
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: controller.panel.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: 125))
        reader.keyDown(with: event)
        #expect(model.isReading)
        #expect(model.snapshot == original)
        reader.cancelOperation(nil)
        #expect(hideRequested)
    }

    @Test func keyboardReaderSurvivesSongChangesAndTabsToConditionalSync() async throws {
        let suite = "lyric-keyboard-transition-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = LyricRibbonModel(snapshot: lyricTestSnapshot())
        let controller = LyricRibbonWindowController(model: model, defaults: defaults, onHide: {})
        defer { controller.hide(); controller.panel.close() }
        controller.show()
        model.completeLoad(.timed(try lyricTestDocument()), token: model.beginLoad())
        controller.refreshLayout(textScale: 1)
        controller.panel.contentView?.layoutSubtreeIfNeeded()
        controller.focusForReading()
        let reader = try #require(controller.panel.firstResponder as? LyricReadingTextView)
        model.beginReading()
        try await Task.sleep(for: .milliseconds(50))
        let tab = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: controller.panel.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t",
            isARepeat: false, keyCode: 48))
        reader.keyDown(with: tab)
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.keyboardSelection == .sync)
        #expect(controller.panel.firstResponder !== reader)
        let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: controller.panel.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36))
        controller.panel.firstResponder?.keyDown(with: enter)
        try await Task.sleep(for: .milliseconds(50))
        #expect(!model.isReading)
        #expect(controller.panel.firstResponder === reader)
        var next = model.snapshot
        next.occurrenceID = "second"
        next.title = "Another original fixture"
        model.update(next)
        model.completeLoad(.timed(try lyricTestDocument()), token: model.beginLoad())
        controller.refreshLayout(textScale: 1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(controller.panel.firstResponder === reader)
        #expect(model.isKeyboardInteracting)
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
        let short = CGRect(x: 0, y: 0, width: 1000, height: 180)
        let content = LyricContent.timed(try LyricDocument(cues: [
            LyricCue(id: "long", startMs: 0, text: String(repeating: "A little room for the rain.\n", count: 100)),
        ]))
        let original = LyricRibbonWindowController.placement(content: content,
            saved: CGRect(x: -900, y: 20, width: 448, height: 157), textScale: 1, screens: [tall, short], preferred: tall)
        let destination = LyricRibbonWindowController.placement(content: content,
            saved: CGRect(x: 50, y: 20, width: 448, height: original.layout.panelSize.height),
            textScale: 1, screens: [tall, short], preferred: tall)
        #expect(original.layout.panelSize.height < 350)
        #expect(destination.layout.panelSize.height <= 140)
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
        #expect(controller.panel.frame.height == shortHeight)
    }
}
