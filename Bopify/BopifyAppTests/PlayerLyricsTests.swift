import AppKit
import SwiftUI
import Testing
import BopifyDomain
import BopifyPlayback

@MainActor @Suite("Player lyrics", .serialized)
struct PlayerLyricsTests {
    @Test func hoveringExpandedLyricsRetainsThePlayerUntilThePointerLeaves() async throws {
        let f = try PlayerLyricsFixture()
        defer { f.close() }
        try await f.show()
        #expect(!f.panel.isKeyWindow)
        f.environment.presentation.sendAttention(.pointer(true))
        f.controller.apply(mode: .expanded, reduceMotion: true, showsLyrics: true)
        let lyrics = f.controller.layout.lyricsFrame
        f.panel.updatePlayerPointer(at: CGPoint(x: lyrics.midX, y: lyrics.midY))
        try await Task.sleep(for: .milliseconds(380))
        #expect(f.environment.presentation.mode == .expanded)
        f.panel.updatePlayerPointer(at: nil)
        try await Task.sleep(for: .milliseconds(380))
        #expect(f.environment.presentation.mode == .compact)
    }

    @Test func providerFooterLeavesThreeReadableRowsInBothModes() async throws {
        let f = try PlayerLyricsFixture()
        defer { f.close() }
        try await f.show()
        #expect(f.model.source?.attribution == "Fixture provider")
        let reader = try #require(f.descendant(LyricReadingTextView.self))
        let scroll = try #require(reader.enclosingScrollView)
        for mode in [PlayerMode.compact, .expanded] {
            f.controller.apply(mode: mode, reduceMotion: true, showsLyrics: true)
            try await Task.sleep(for: .milliseconds(80))
            #expect(scroll.contentView.bounds.height >= 84)
        }
    }

    @Test func vinylClickExpandsWithoutTogglingPlayback() async throws {
        let f = try PlayerLyricsFixture()
        defer { f.close() }
        try await f.show()
        var toggles = 0
        f.panel.onTogglePlayback = { toggles += 1 }
        let center = f.controller.layout.recordCenter
        let point = CGPoint(x: center.x, y: f.panel.frame.height - center.y)
        f.panel.sendEvent(try f.event(.leftMouseDown, at: point))
        f.panel.sendEvent(try f.event(.leftMouseUp, at: point))
        #expect(toggles == 0)
        #expect(f.panel.isKeyWindow && f.environment.presentation.mode == .expanded)
    }

    @Test func hoveringTheMiniVinylNeverExpandsThePlayer() async throws {
        let f = try PlayerLyricsFixture()
        defer { f.close() }
        try await f.show()
        f.panel.updatePlayerPointer(at: f.controller.layout.recordCenter)
        try await Task.sleep(for: .milliseconds(1300))
        #expect(f.environment.presentation.mode == .compact)
        #expect(!f.panel.isKeyWindow)
    }

    @Test(arguments: [false, true])
    func animatedCollapseReleasesTheExpandedWindowFrame(interrupted: Bool) async throws {
        let f = try PlayerLyricsFixture()
        defer { f.close() }
        try await f.show()
        f.panel.onPointerChanged = nil
        func waitForTransition() async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while f.controller.isTransitioning, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(!f.controller.isTransitioning)
        }
        f.environment.presentation.sendAttention(.keyboardFocus(true))
        f.controller.apply(mode: .expanded, reduceMotion: false, showsLyrics: true)
        if interrupted { try await Task.sleep(for: .milliseconds(80)) }
        else { try await waitForTransition() }
        f.environment.presentation.resetEngagement()
        f.controller.apply(mode: .compact, reduceMotion: false, showsLyrics: true)
        try await waitForTransition()
        #expect(f.panel.frame.size == CGSize(width: 380, height: 178))
        #expect(f.controller.contentOffset == .zero)
    }

    @Test func vinylDragsWithoutRevealingOrTogglingPlayback() async throws {
        let f = try PlayerLyricsFixture()
        defer { f.close() }
        try await f.show()
        var toggles = 0
        f.panel.onTogglePlayback = { toggles += 1 }
        let center = f.controller.layout.recordCenter
        let point = CGPoint(x: center.x, y: f.panel.frame.height - center.y)
        f.panel.updatePlayerPointer(at: center)
        #expect(f.environment.presentation.mode == .compact)
        let origin = f.panel.frame.origin
        f.panel.sendEvent(try f.event(.leftMouseDown, at: point))
        f.panel.sendEvent(try f.event(.leftMouseDragged, at: CGPoint(x: point.x + 80, y: point.y)))
        #expect(f.panel.frame.minX == origin.x + 80)
        #expect(f.environment.presentation.mode == .compact && !f.panel.isKeyWindow)
        f.panel.sendEvent(try f.event(.leftMouseUp, at: point))
        #expect(toggles == 0)
        #expect(!f.controller.isDragging)
        try await Task.sleep(for: .milliseconds(1300))
        #expect(f.environment.presentation.mode == .compact)
    }

    @Test(arguments: [CGFloat(0), 30], [false, true])
    func lyricClicksAndSelectionsPreservePresentationMode(dragDistance: CGFloat, expanded: Bool) async throws {
        let f = try PlayerLyricsFixture()
        defer { f.close() }
        try await f.show(expanded: expanded)
        let reader = try #require(f.descendant(LyricReadingTextView.self))
        let manager = try #require(reader.layoutManager)
        let container = try #require(reader.textContainer)
        let range = (reader.string as NSString).range(of: "Current words")
        let glyph = manager.glyphIndexForCharacter(at: range.location)
        let box = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        let point = reader.convert(CGPoint(x: box.midX, y: box.midY), to: nil)
        let destination = CGPoint(x: point.x + dragDistance, y: point.y)
        NSApp.postEvent(try f.event(.leftMouseUp, at: destination), atStart: true)
        if dragDistance > 0 { NSApp.postEvent(try f.event(.leftMouseDragged, at: destination), atStart: true) }
        f.panel.sendEvent(try f.event(.leftMouseDown, at: point))
        f.panel.updatePlayerPointer(at: nil)
        try await Task.sleep(for: .milliseconds(380))
        #expect(f.seekTargets == (dragDistance == 0 ? [70_000] : []))
        if dragDistance > 0 { #expect(reader.selectedRange().length > 0) }
        #expect(f.panel.isKeyWindow == expanded)
        #expect(f.environment.presentation.mode == (expanded ? .expanded : .compact))
    }

    @Test func manualReadingSurvivesExpansionAndCollapse() async throws {
        let f = try PlayerLyricsFixture()
        defer { f.close() }
        try await f.show()
        f.model.beginReading()
        try await Task.sleep(for: .milliseconds(50))
        let reader = try #require(f.descendant(LyricReadingTextView.self))
        let scroll = try #require(reader.enclosingScrollView)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 14))
        let selection = NSRange(location: 2, length: 4)
        reader.setSelectedRange(selection)
        let origin = scroll.contentView.bounds.origin
        for mode in [PlayerMode.expanded, .compact] {
            f.controller.apply(mode: mode, reduceMotion: true, showsLyrics: true)
            try await Task.sleep(for: .milliseconds(50))
            #expect(f.descendant(LyricReadingTextView.self) === reader)
            #expect(reader.selectedRange() == selection)
            #expect(scroll.contentView.bounds.origin == origin)
            #expect(f.model.isReading)
        }
    }

    @Test func scrollingLyricsLeavesThePlayerCompact() async throws {
        let f = try PlayerLyricsFixture()
        defer { f.close() }
        try await f.show()
        let scroll = try #require(f.descendant(LyricReadingScrollView.self))
        let wheel = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 30, wheel2: 0, wheel3: 0))
        scroll.scrollWheel(with: try #require(NSEvent(cgEvent: wheel)))
        #expect(f.model.isReading)
        #expect(!f.panel.isKeyWindow)
        #expect(f.environment.presentation.mode == .compact)
    }

    @Test(arguments: [false, true])
    func syncClickPreservesPresentationMode(expanded: Bool) async throws {
        let f = try PlayerLyricsFixture()
        defer { f.close() }
        try await f.show(expanded: expanded)
        f.model.beginReading()
        try await Task.sleep(for: .milliseconds(80))
        let lyric = f.controller.layout.lyricsFrame
        let point = CGPoint(x: lyric.maxX - 42, y: f.panel.frame.height - lyric.maxY + 23)
        NSApp.postEvent(try f.event(.leftMouseUp, at: point), atStart: true)
        f.panel.sendEvent(try f.event(.leftMouseDown, at: point))
        while let up = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
            f.panel.sendEvent(up)
        }
        f.panel.updatePlayerPointer(at: nil)
        try await Task.sleep(for: .milliseconds(380))
        #expect(!f.model.isReading)
        #expect(f.panel.isKeyWindow == expanded)
        #expect(f.environment.presentation.mode == (expanded ? .expanded : .compact))
    }

    @Test(arguments: [false, true])
    func keyboardReadingAndSyncPreservePresentationMode(expanded: Bool) async throws {
        let f = try PlayerLyricsFixture()
        defer { f.close() }
        try await f.show(expanded: expanded)
        f.model.isKeyboardInteracting = true
        f.model.keyboardSelection = .reader
        f.controller.focusLyrics()
        #expect(f.panel.isKeyWindow)
        #expect(f.panel.firstResponder is LyricReadingTextView)
        try await Task.sleep(for: .milliseconds(380))
        #expect(f.environment.presentation.mode == (expanded ? .expanded : .compact))
        f.model.beginReading()
        let tab = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: f.panel.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
        f.panel.keyDown(with: tab)
        #expect(f.model.keyboardSelection == .sync)
        try await Task.sleep(for: .milliseconds(50))
        let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: f.panel.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        f.panel.keyDown(with: enter)
        #expect(!f.model.isReading && f.model.keyboardSelection == .reader)
        try await Task.sleep(for: .milliseconds(380))
        #expect(f.environment.presentation.mode == (expanded ? .expanded : .compact))
    }

    @Test(arguments: [false, true])
    func leavingKeyboardReadingReleasesTheReaderFocus(returnToPlayer: Bool) async throws {
        let f = try PlayerLyricsFixture()
        defer { f.close() }
        try await f.show()
        f.model.isKeyboardInteracting = true
        f.model.keyboardSelection = .reader
        f.controller.focusLyrics()
        if returnToPlayer { f.controller.focus() }
        else { f.panel.resignKey() }
        #expect(!f.model.isKeyboardInteracting)
        #expect(f.model.keyboardSelection == nil)
    }

    @Test func hidingFocusedLyricsRestoresThePlayerSpaceShortcut() async throws {
        let f = try PlayerLyricsFixture()
        defer { f.close() }
        try await f.show()
        f.model.isKeyboardInteracting = true
        f.model.keyboardSelection = .reader
        f.controller.focusLyrics()
        var toggles = 0
        f.panel.onTogglePlayback = { toggles += 1 }
        f.model.hide()
        f.controller.apply(mode: .compact, reduceMotion: true)
        try await Task.sleep(for: .milliseconds(50))
        let space = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: f.panel.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        f.panel.keyDown(with: space)
        #expect(toggles == 1)
    }
}

@MainActor private final class PlayerLyricsFixture {
    let environment = makePreviewEnvironment(.paused)
    let model = LyricRibbonModel(snapshot: lyricTestSnapshot())
    let controller: PlayerWindowController
    let panel: StatusPanel
    var seekTargets: [Int64] { seeks.values }
    private let seeks = LyricSeekTargets()
    private let suite = "player-lyrics-\(UUID().uuidString)"
    private let defaults: UserDefaults
    private let eventTime = ProcessInfo.processInfo.systemUptime

    init() throws {
        _ = NSApplication.shared
        defaults = try #require(UserDefaults(suiteName: suite))
        controller = PlayerWindowController(defaults: defaults)
        let seeks = seeks
        let root = RecordPlayerView(player: environment.player!, artworkStore: environment.artworkStore,
            presentation: environment.presentation, windowController: controller, lyricModel: model,
            onLyricSeek: { time, _ in seeks.values.append(time) }).environment(environment)
        panel = StatusPanel(content: root)
        panel.isReleasedWhenClosed = false
        panel.onKeyChanged = { [weak self] in self?.environment.presentation.sendAttention(.keyboardFocus($0)) }
        panel.onPointerChanged = { [weak self] in self?.environment.presentation.sendAttention(.pointer($0)) }
        controller.attach(to: panel)
    }

    func show(expanded: Bool = false) async throws {
        model.show()
        model.completeLoad(.timed(try LyricDocument(cues: [
            LyricCue(id: "previous", startMs: 60_000, text: "Previous words"),
            LyricCue(id: "current", startMs: 70_000, text: "Current words"),
            LyricCue(id: "next", startMs: 80_000, text: "Upcoming words"),
        ])), token: model.beginLoad(), source: LyricSourceMetadata(lyrics: TrackLyrics(
            trackURI: previewTracks[0].uri, synchronization: .lineSynced, lines: [],
            provider: "fixture", providerDisplayName: "Fixture provider", language: "en", isRightToLeft: false)))
        environment.presentation.isVisible = true
        controller.apply(mode: expanded ? .expanded : .compact, reduceMotion: true, showsLyrics: true)
        panel.orderFrontRegardless()
        if expanded { controller.focus() }
        panel.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
    }

    func close() {
        environment.presentation.resetEngagement()
        environment.player?.stop()
        panel.orderOut(nil)
        panel.close()
        defaults.removePersistentDomain(forName: suite)
    }

    func descendant<T: NSView>(_ type: T.Type) -> T? {
        func search(_ view: NSView) -> T? {
            if let match = view as? T { return match }
            return view.subviews.lazy.compactMap(search).first
        }
        return panel.contentView.flatMap(search)
    }

    func event(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
        let delay: TimeInterval = type == .leftMouseUp ? 0.1 : type == .leftMouseDragged ? 0.05 : 0
        return try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: eventTime + delay,
            windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }
}

@MainActor private final class LyricSeekTargets { var values: [Int64] = [] }
