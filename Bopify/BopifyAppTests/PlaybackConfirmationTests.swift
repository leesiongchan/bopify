import AppKit
import Carbon.HIToolbox
import SwiftUI
import Testing
import BopifyDomain
import BopifyPlayback

@MainActor @Suite("Playback confirmation", .serialized)
struct PlaybackConfirmationTests {
    @Test func slowConfirmationOutlivesTheClickAnimation() async throws {
        let f = PlaybackAuditFixture(name: "slow")
        defer { f.close() }
        try await f.ready()
        let before = try f.frame("before")
        try f.click()
        try await liveLyricEventually { f.engine.commands == ["pause"] }
        try await Task.sleep(for: .milliseconds(100))
        let early = try f.frame("click-100ms")
        try await Task.sleep(for: .milliseconds(550))
        let waiting = try f.frame("unconfirmed-650ms")
        #expect(f.player.state.phase == .playing)
        f.engine.emit(.paused(positionMs: 1000))
        try await liveLyricEventually { f.player.state.phase == .paused }
        try await Task.sleep(for: .milliseconds(20))
        let confirmed = try f.frame("confirmed-20ms")
        try await Task.sleep(for: .milliseconds(500))
        let settled = try f.frame("confirmed-520ms")
        f.report("click100 vs before", early, before)
        f.report("unconfirmed650 vs before", waiting, before)
        #expect(f.difference(confirmed, settled) > 100, "Confirmation must begin the icon transition even after a slow command")
        f.report("old vs new settled glyph", waiting, settled)
        #expect(f.difference(waiting, settled) > 100, "Confirmed pause must replace the settled playing glyph")
    }

    @Test func spaceAndExternalEventsChangeStateWithoutAClickTrigger() async throws {
        let f = PlaybackAuditFixture(name: "external")
        defer { f.close() }
        try await f.ready()
        let initial = try f.frame("playing-before-space")
        let space = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: f.panel.windowNumber,
            context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false,
            keyCode: UInt16(kVK_Space)))
        f.panel.makeFirstResponder(nil)
        f.panel.keyDown(with: space)
        try await liveLyricEventually { f.engine.commands == ["pause"] }
        #expect(f.player.state.phase == .playing)
        try await Task.sleep(for: .milliseconds(100))
        let unconfirmed = try f.frame("space-unconfirmed-100ms")
        f.engine.emit(.paused(positionMs: 1000))
        try await liveLyricEventually { f.player.state.phase == .paused }
        try await Task.sleep(for: .milliseconds(20))
        let confirmed = try f.frame("space-confirmed-20ms")
        try await Task.sleep(for: .milliseconds(500))
        let paused = try f.frame("space-confirmed-520ms")
        f.report("space unconfirmed vs initial", unconfirmed, initial)
        #expect(f.difference(confirmed, paused) > 100, "Keyboard confirmation must animate the same icon change")
        f.engine.emit(.playing(positionMs: 1000))
        try await liveLyricEventually { f.player.state.phase == .playing }
        try await Task.sleep(for: .milliseconds(20))
        let external = try f.frame("engine-playing-20ms")
        try await Task.sleep(for: .milliseconds(500))
        let final = try f.frame("engine-playing-520ms")
        #expect(f.engine.commands == ["pause"])
        #expect(f.difference(external, final) > 100)
        f.report("external playing vs paused", final, paused)
        #expect(f.difference(final, paused) > 100, "External playback must replace the settled paused glyph")
    }

}

@MainActor private final class PlaybackAuditFixture {
    let engine = LiveLyricTestEngine()
    let player: PlayerModel
    let panel: StatusPanel
    let name: String
    private let output = URL(fileURLWithPath: "/tmp/bopify-playback-audit", isDirectory: true)

    init(name: String) {
        _ = NSApplication.shared
        self.name = name
        player = PlayerModel(engine: engine)
        let player = player
        panel = StatusPanel(content: TransportControls(player: player)
            .frame(width: 240, height: 100).background(.black).environment(\.colorScheme, .dark))
        panel.setFrame(CGRect(x: 300, y: 300, width: 240, height: 100), display: false)
        panel.isReleasedWhenClosed = false
        panel.onTogglePlayback = {
            if player.state.isActiveDevice {
                guard player.state.phase == .playing || player.state.phase == .paused else { return }
            } else {
                guard player.canPlayHere, player.state.phase != .loading else { return }
            }
            player.togglePlayPause()
        }
        player.start()
    }

    func ready() async throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        engine.emit(.trackChanged(liveLyricTrack()))
        engine.emit(.playing(positionMs: 1000))
        try await liveLyricEventually { self.player.state.phase == .playing && self.player.state.currentTrack != nil }
        panel.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(200))
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    func click() throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            panel.sendEvent(try #require(NSEvent.mouseEvent(with: type,
                location: CGPoint(x: 120, y: 50), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0)))
        }
    }

    func frame(_ label: String) throws -> [UInt8] {
        let view = try #require(panel.contentView)
        view.layoutSubtreeIfNeeded()
        let rect = CGRect(x: view.bounds.midX - 32, y: view.bounds.midY - 32, width: 64, height: 64)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: rect))
        view.cacheDisplay(in: rect, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: output.appendingPathComponent("\(name)-\(label).png"))
        var values: [UInt8] = []
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                values += [color.redComponent, color.greenComponent, color.blueComponent].map {
                    UInt8(max(0, min(255, ($0 * 255).rounded())))
                }
            }
        }
        return values
    }

    func difference(_ a: [UInt8], _ b: [UInt8]) -> Int {
        zip(a, b).filter { abs(Int($0.0) - Int($0.1)) > 3 }.count
    }

    func report(_ label: String, _ a: [UInt8], _ b: [UInt8]) {
        let changes = zip(a, b).filter { abs(Int($0.0) - Int($0.1)) > 3 }.count
        print("PLAYBACK_AUDIT \(name) \(label): changed RGB channels=\(changes)/\(min(a.count, b.count))")
    }

    func close() { player.stop(); panel.orderOut(nil); panel.close() }
}
