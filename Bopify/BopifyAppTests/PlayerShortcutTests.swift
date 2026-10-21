import AppKit
import Carbon.HIToolbox
import SwiftUI
import Testing
import BopifyDomain
import BopifyLibrary
import BopifyPlayback

@MainActor @Suite("Player shortcuts", .serialized)
struct PlayerShortcutTests {
    @Test func searchRevealsTheHiddenPlayerAndFocusesTheRetainedQuery() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.environment.search.updateQuery("Mira")
        await fixture.environment.search.search()
        let results = fixture.environment.search.results
        #expect(!fixture.panel.isVisible)

        fixture.panel.onSearch?()

        #expect(fixture.panel.isVisible)
        #expect(fixture.environment.presentation.isVisible)
        try await waitUntil {
            NSApp.windows.contains { window in
                guard window.isVisible, window.isKeyWindow, let field = searchField(in: window.contentView) else { return false }
                return field.currentEditor() === window.firstResponder
            }
        }
        #expect(fixture.environment.searchPopover.isVisible)
        #expect(fixture.environment.search.query == "Mira")
        #expect(fixture.environment.search.results == results)
        let revision = fixture.environment.searchPopover.focusRevision
        fixture.panel.onSearch?()
        #expect(fixture.panel.isVisible)
        #expect(fixture.environment.searchPopover.focusRevision == revision + 1)
        try await waitUntil {
            NSApp.windows.contains { window in
                guard window.isVisible, window.isKeyWindow, let field = searchField(in: window.contentView) else { return false }
                return field.currentEditor() === window.firstResponder && field.stringValue == "Mira"
            }
        }
        #expect(fixture.environment.searchPopover.isVisible)
    }

    @Test func commandSlashOpensAndReusesTheShortcutReferenceWhileEditing() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let editor = NSTextView()
        fixture.panel.contentView?.addSubview(editor)
        fixture.panel.makeFirstResponder(editor)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: fixture.panel.windowNumber, context: nil, characters: "/",
            charactersIgnoringModifiers: "/", isARepeat: false, keyCode: UInt16(kVK_ANSI_Slash)))

        #expect(fixture.panel.performKeyEquivalent(with: event))

        let reference = try #require(NSApp.windows.first { $0.identifier?.rawValue == "keyboard-shortcuts" })
        defer { reference.close() }
        #expect(reference.isVisible)
        #expect(fixture.panel.performKeyEquivalent(with: event))
        #expect(NSApp.windows.filter { $0.identifier?.rawValue == "keyboard-shortcuts" }.count == 1)
    }

    @Test func playerShortcutHidesSearchAndCanRevealThePlayerAgain() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.controller.togglePlayer()
        fixture.panel.onSearch?()
        #expect(fixture.environment.searchPopover.isVisible)

        fixture.controller.togglePlayer()

        #expect(!fixture.panel.isVisible)
        #expect(!fixture.environment.searchPopover.isVisible)
        #expect(!fixture.environment.presentation.isVisible)
        fixture.controller.togglePlayer()
        #expect(fixture.panel.isVisible && fixture.panel.isKeyWindow)
    }

    @Test func firstRecordDragPermanentlyDismissesTheSeekHint() async throws {
        let key = "record.hasScrubbed"
        let saved = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(false, forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.controller.togglePlayer()
        try await waitUntil { recordPointer(in: fixture.panel.contentView)?.bounds.width ?? 0 > 0 }
        let pointer = try #require(recordPointer(in: fixture.panel.contentView))
        let start = pointer.convert(CGPoint(x: pointer.bounds.midX + 50, y: pointer.bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: fixture.panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        pointer.mouseDown(with: try event(.leftMouseDown, at: start))
        pointer.mouseUp(with: try event(.leftMouseUp, at: start))
        #expect(!UserDefaults.standard.bool(forKey: key))

        pointer.mouseDown(with: try event(.leftMouseDown, at: start))
        pointer.mouseDragged(with: try event(.leftMouseDragged, at: CGPoint(x: start.x - 20, y: start.y + 30)))
        pointer.mouseUp(with: try event(.leftMouseUp, at: CGPoint(x: start.x - 20, y: start.y + 30)))

        #expect(UserDefaults.standard.bool(forKey: key))
        fixture.controller.togglePlayer()
        fixture.controller.togglePlayer()
        #expect(UserDefaults.standard.bool(forKey: key))
    }

    private func recordPointer(in view: NSView?) -> RecordPointerRegion.PointerView? {
        if let pointer = view as? RecordPointerRegion.PointerView { return pointer }
        return view?.subviews.lazy.compactMap { recordPointer(in: $0) }.first
    }

    private func waitUntil(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition(), sourceLocation: sourceLocation)
    }

    private func searchField(in view: NSView?) -> NSTextField? {
        if let field = view as? NSTextField, field.identifier?.rawValue == "catalog-search-input" { return field }
        return view?.subviews.lazy.compactMap { searchField(in: $0) }.first
    }

    @MainActor private struct Fixture {
        let environment: AppEnvironment
        let controller: StatusItemController
        let panel: StatusPanel
        private let keys = ["player.frame", "player.keepOnTop", "player.recordCenter"]
        private let saved: [Any?]

        init() throws {
            _ = NSApplication.shared
            saved = keys.map { UserDefaults.standard.object(forKey: $0) }
            let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
            environment = makePreviewEnvironment(.paused)
            controller = StatusItemController(content: PlayerRootView(environment: environment), environment: environment)
            panel = try #require(NSApp.windows.compactMap { $0 as? StatusPanel }
                .first { !existing.contains(ObjectIdentifier($0)) })
            panel.isReleasedWhenClosed = false
        }

        func close() {
            environment.searchPopover.close()
            environment.player?.stop()
            panel.orderOut(nil)
            panel.close()
            for (key, value) in zip(keys, saved) {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
    }
}
