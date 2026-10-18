import AppKit
import Testing
import SwiftUI

@MainActor @Suite("Lyric ribbon window", .serialized)
struct LyricRibbonWindowTests {
    @Test func windowServerTargetsTheWholeSurfaceAfterLyricsLoad() async throws {
        let suite = "lyric-window-target-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = LyricRibbonModel(snapshot: lyricTestSnapshot())
        let controller = LyricRibbonWindowController(model: model, defaults: defaults, onHide: {})
        defer { controller.hide(); controller.panel.close() }
        controller.show()
        model.completeLoad(.timed(try lyricTestDocument()), token: model.beginLoad())
        controller.refreshLayout(textScale: 1)
        controller.panel.contentView?.layoutSubtreeIfNeeded()
        controller.panel.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        controller.panel.orderFront(nil)
        let content = try #require(controller.panel.contentView)
        // sendEvent and view hitTest bypass the WindowServer's transparent-window targeting.
        for point in [CGPoint(x: 56, y: 73), CGPoint(x: 430, y: 72),
                      CGPoint(x: 412, y: 56), CGPoint(x: 200, y: 7)] {
            let screenPoint = controller.panel.convertPoint(toScreen: content.convert(point, to: nil))
            #expect(NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0) == controller.panel.windowNumber)
        }
        #expect(controller.panel.level == .floating)
        #expect(!controller.panel.canBecomeKey)
    }

    @Test(arguments: [CGPoint(x: 200, y: 7), CGPoint(x: 441, y: 70), CGPoint(x: 56, y: 70),
                      CGPoint(x: 200, y: 139), CGPoint(x: 414, y: 70), CGPoint(x: 220, y: 128), CGPoint(x: 435, y: 128)])
    func exposedBorderDragsPassivelyAndReturnsToVisibleScreen(point: CGPoint) async throws {
        let suite = "lyric-border-drag-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = LyricRibbonModel(snapshot: lyricTestSnapshot())
        model.completeLoad(.timed(try LyricDocument(cues: [
            LyricCue(id: "previous", startMs: 60_000, text: "Previous"),
            LyricCue(id: "current", startMs: 70_000, text: "Current"),
            LyricCue(id: "next", startMs: 80_000, text: "Next"),
        ])), token: model.beginLoad())
        let controller = LyricRibbonWindowController(model: model, defaults: defaults, onHide: {})
        defer { controller.hide(); controller.panel.close() }
        controller.show()
        controller.panel.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        let content = try #require(controller.panel.contentView)
        let original = controller.panel.frame
        let outsideX = try #require(NSScreen.screens.map(\.visibleFrame.minX).min()) - 300
        let point = content.convert(point, to: nil)
        func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: controller.panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        NSApp.postEvent(try event(.leftMouseUp, point), atStart: true)
        NSApp.postEvent(try event(.leftMouseDragged, CGPoint(x: point.x + outsideX - original.minX, y: point.y)), atStart: true)
        controller.panel.sendEvent(try event(.leftMouseDown, point))
        var reachedOutside = abs(controller.panel.frame.minX - outsideX) < 1
        while let pending = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: Date(), inMode: .default, dequeue: true) {
            controller.panel.sendEvent(pending)
            reachedOutside = reachedOutside || abs(controller.panel.frame.minX - outsideX) < 1
        }
        #expect(reachedOutside)
        try await Task.sleep(for: .milliseconds(900))
        #expect(NSScreen.screens.contains { $0.visibleFrame.insetBy(dx: -1, dy: -1).contains(controller.panel.frame) })
        #expect(!controller.panel.canBecomeKey)
        #expect(defaults.string(forKey: "lyrics.preview.frame") == NSStringFromRect(controller.panel.frame))
    }

    @Test(arguments: [false, true])
    func scrollbarIsAbsentDuringFollowingAndAvailableForManualOrPlainReading(plain: Bool) async throws {
        let suite = "lyric-scroller-mode-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = LyricRibbonModel(snapshot: lyricTestSnapshot())
        let lyrics: LyricContent = plain ? .plain(String(repeating: "A quiet room.\n", count: 30)) : .timed(try lyricTestDocument())
        model.completeLoad(lyrics, token: model.beginLoad())
        let controller = LyricRibbonWindowController(model: model, defaults: defaults, onHide: {})
        defer { controller.hide(); controller.panel.close() }
        controller.show()
        controller.panel.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        func passage(in view: NSView) -> NSScrollView? {
            if let scroll = view as? LyricReadingScrollView { return scroll }
            return view.subviews.lazy.compactMap { passage(in: $0) }.first
        }
        let scroll = try #require(controller.panel.contentView.flatMap { passage(in: $0) })
        let width = scroll.contentSize.width
        #expect(scroll.hasVerticalScroller == plain)
        model.beginReading()
        try await Task.sleep(for: .milliseconds(50))
        #expect(scroll.hasVerticalScroller)
        #expect(scroll.contentSize.width == width)
        let scroller = try #require(scroll.verticalScroller)
        scroller.isHidden = true
        let content = try #require(controller.panel.contentView)
        let gutter = scroller.convert(CGPoint(x: scroller.bounds.midX, y: scroller.bounds.midY), to: content)
        #expect(content.hitTest(gutter) is PlayerBackgroundDragRegion.DragView)
        scroller.isHidden = false
        model.backToLive()
        try await Task.sleep(for: .milliseconds(50))
        #expect(scroll.hasVerticalScroller == plain)
        #expect(scroll.contentSize.width == width)
    }

    @Test func wheelThroughTheBlankSurfaceScrollsLyricsWithoutTakingFocus() async throws {
        let suite = "lyric-surface-wheel-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = LyricRibbonModel(snapshot: lyricTestSnapshot())
        model.completeLoad(.timed(try lyricTestDocument()), token: model.beginLoad())
        let controller = LyricRibbonWindowController(model: model, defaults: defaults, onHide: {})
        defer { controller.hide(); controller.panel.close() }
        controller.show()
        controller.panel.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            if let match = view as? T { return match }
            return view.subviews.lazy.compactMap { descendant(type, in: $0) }.first
        }
        let content = try #require(controller.panel.contentView)
        let scroll = try #require(descendant(LyricReadingScrollView.self, in: content))
        let overlay = try #require(descendant(PlayerBackgroundDragRegion.DragView.self, in: content))
        let before = scroll.contentView.bounds.minY
        let wheel = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 30, wheel2: 0, wheel3: 0))
        overlay.scrollWheel(with: try #require(NSEvent(cgEvent: wheel)))
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.isReading)
        #expect(scroll.contentView.bounds.minY < before)
        #expect(scroll.hasVerticalScroller)
        #expect(!controller.panel.canBecomeKey)
    }

    @Test func syncRemainsClickableThroughTheSurfaceDragLayer() async throws {
        let suite = "lyric-sync-pointer-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = LyricRibbonModel(snapshot: lyricTestSnapshot())
        model.completeLoad(.timed(try lyricTestDocument()), token: model.beginLoad())
        let controller = LyricRibbonWindowController(model: model, defaults: defaults, onHide: {})
        defer { controller.hide(); controller.panel.close() }
        controller.show()
        model.beginReading()
        controller.panel.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        let point = CGPoint(x: controller.panel.frame.width - 48, y: controller.panel.frame.height - 27)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: controller.panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        NSApp.postEvent(try event(.leftMouseUp), atStart: true)
        controller.panel.sendEvent(try event(.leftMouseDown))
        while let up = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
            controller.panel.sendEvent(up)
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!model.isReading)
        #expect(!controller.panel.canBecomeKey)
    }

    @Test func sharedDragDefaultsKeepMainPlayerFocusAndCallbacks() throws {
        let panel = StatusPanel(content: EmptyView())
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let drag = PlayerBackgroundDragRegion.DragView(frame: panel.contentView!.bounds)
        panel.contentView = drag
        panel.orderFront(nil)
        var changes: [Bool] = []
        panel.onWindowDragChanged = { changes.append($0) }
        let origin = panel.frame.origin
        func event(_ type: NSEvent.EventType, _ x: CGFloat) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: 30), modifierFlags: [],
                timestamp: 0, windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        drag.mouseDown(with: try event(.leftMouseDown, 30))
        #expect(panel.isKeyWindow)
        drag.mouseDragged(with: try event(.leftMouseDragged, 40))
        #expect(panel.frame.origin.x == origin.x + 10)
        drag.mouseUp(with: try event(.leftMouseUp, 30))
        #expect(changes == [true, false])
    }

    @Test func preparingAnInterruptedDragKeepsTheGlobalPointerOrigin() throws {
        let panel = NSPanel(contentRect: CGRect(x: 100, y: 100, width: 448, height: 156),
            styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let drag = PlayerBackgroundDragRegion.DragView(frame: CGRect(x: 0, y: 0, width: 448, height: 156))
        drag.takesKeyboardFocus = false
        panel.contentView = drag
        var changes: [Bool] = []
        drag.onDragChanged = { changes.append($0) }
        drag.onPrepareDrag = { panel.setFrameOrigin(CGPoint(x: 200, y: 100)) }
        func event(_ type: NSEvent.EventType, _ x: CGFloat) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: 30), modifierFlags: [],
                timestamp: 0, windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        drag.mouseDown(with: try event(.leftMouseDown, 120))
        drag.mouseDragged(with: try event(.leftMouseDragged, 23))
        #expect(panel.frame.minX == 200)
        #expect(changes.isEmpty)
        drag.mouseDragged(with: try event(.leftMouseDragged, 25))
        #expect(panel.frame.minX == 205)
        drag.mouseUp(with: try event(.leftMouseUp, 20))
        #expect(changes == [true, false])
    }

    @Test func hideDuringSpringPersistsTheDestinationAndRejectsStaleCompletion() async throws {
        let suite = "lyric-spring-hide-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = LyricRibbonWindowController(model: LyricRibbonModel(snapshot: lyricTestSnapshot()),
            defaults: defaults, onHide: {})
        defer { controller.hide(); controller.panel.close() }
        controller.show()
        let visible = try #require(controller.panel.screen?.visibleFrame)
        controller.setDragging(true)
        controller.panel.setFrameOrigin(CGPoint(x: visible.minX - 200, y: visible.minY - 100))
        controller.refreshLayout(textScale: 1.5)
        #expect(controller.panel.frame.minX == visible.minX - 200)
        controller.setDragging(false)
        controller.hide()
        let saved = NSRectFromString(try #require(defaults.string(forKey: "lyrics.preview.frame")))
        #expect(visible.contains(saved))
        controller.show()
        let restored = controller.panel.frame
        try await Task.sleep(for: .milliseconds(900))
        #expect(controller.panel.frame == restored)
        #expect(visible.contains(restored))
        #expect(restored.height > 156)
    }

    @Test func secondDragDuringSpringKeepsItsPointerDeltaAndDestination() async throws {
        let suite = "lyric-spring-interrupt-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = LyricRibbonWindowController(model: LyricRibbonModel(snapshot: lyricTestSnapshot()),
            defaults: defaults, onHide: {})
        defer { controller.hide(); controller.panel.close() }
        controller.show()
        let visible = try #require(controller.panel.screen?.visibleFrame)
        controller.setDragging(true)
        controller.panel.setFrameOrigin(CGPoint(x: visible.minX - 200, y: visible.minY + 50))
        controller.setDragging(false)
        controller.panel.contentView?.layoutSubtreeIfNeeded()
        func region(in view: NSView) -> PlayerBackgroundDragRegion.DragView? {
            if let drag = view as? PlayerBackgroundDragRegion.DragView { return drag }
            return view.subviews.lazy.compactMap { region(in: $0) }.first
        }
        let drag = try #require(controller.panel.contentView.flatMap { region(in: $0) })
        let screenPoint = controller.panel.convertPoint(toScreen: CGPoint(x: 220, y: 7))
        func event(_ type: NSEvent.EventType, screen: CGPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: controller.panel.convertPoint(fromScreen: screen),
                modifierFlags: [], timestamp: 0, windowNumber: controller.panel.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 1))
        }
        drag.mouseDown(with: try event(.leftMouseDown, screen: screenPoint))
        let settled = controller.panel.frame
        let moved = CGPoint(x: screenPoint.x + 5, y: screenPoint.y)
        drag.mouseDragged(with: try event(.leftMouseDragged, screen: moved))
        #expect(controller.panel.frame.minX == settled.minX + 5)
        drag.mouseUp(with: try event(.leftMouseUp, screen: moved))
        try await Task.sleep(for: .milliseconds(900))
        #expect(controller.panel.frame.minX == settled.minX + 5)
        #expect(visible.contains(controller.panel.frame))
    }

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

    @Test(arguments: [CGFloat(0), 10, 120])
    func nativeTextPointerSeeksOnClickAndSelectsOnDragWithoutTakingFocus(dragDistance: CGFloat) async throws {
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
        let destination = CGPoint(x: point.x + dragDistance, y: point.y)
        let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: destination, modifierFlags: [],
            timestamp: down.timestamp + 0.1, windowNumber: controller.panel.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
        NSApp.postEvent(up, atStart: true)
        if dragDistance > 0 {
            let drag = try #require(NSEvent.mouseEvent(with: .leftMouseDragged, location: destination, modifierFlags: [],
                timestamp: down.timestamp + 0.05, windowNumber: controller.panel.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            NSApp.postEvent(drag, atStart: true)
        }
        controller.panel.sendEvent(down)
        #expect(targets == (dragDistance == 0 ? [70_000] : []))
        if dragDistance > 0 { #expect(reader.selectedRange().length > 0) }
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
