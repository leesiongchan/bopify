import SwiftUI
import BopifyPlayback
import BopifyDomain

@main struct MonolithCompositionProbe {
    private actor Library: LibraryService {
        var mutations: [SpotifyURI] = []
        func savedState(for uri: SpotifyURI) async throws -> Bool { false }
        func save(_ uri: SpotifyURI) async throws { mutations.append(uri) }
        func remove(_ uri: SpotifyURI) async throws { mutations.append(uri) }
    }
    @MainActor static var failures: [String] = []
    @MainActor static func check(_ value: Bool, _ message: String) {
        print("\(value ? "PASS" : "FAIL"): \(message)")
        if !value { failures.append(message) }
        fflush(nil)
    }
    @MainActor static func settle() async { try? await Task.sleep(for: .milliseconds(900)) }
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)
        Task { @MainActor in
            let engine = StubPlaybackEngine()
            let player = PlayerModel(engine: engine)
            player.start()
            let library = Library()
            let environment = AppEnvironment(previewPlayer: player, favoriteService: library)
            let status = StatusItemController(content: MiniPlayerView(environment: environment), environment: environment)
            let panel = app.windows.compactMap { $0 as? StatusPanel }.first!
            status.perform(NSSelectorFromString("handleClick"))
            await settle()
            check(panel.isVisible && panel.frame.height >= 560, "startup shell reachable")
            let first = Track(uri: SpotifyURI("spotify:track:first")!, title: "First track", artists: [], albumTitle: nil, artwork: nil, durationMs: 240000)
            let second = Track(uri: SpotifyURI("spotify:track:second")!, title: "Second track", artists: [], albumTitle: nil, artwork: nil, durationMs: 240000)
            engine.emit(.trackChanged(first))
            engine.emit(.paused(positionMs: 1545))
            await settle()
            check(environment.presentation.mode == .expanded && panel.frame.size == CGSize(width: 484, height: 360)
                  && !environment.monolithWindow.isTransitioning, "first track settles to tight listening geometry")
            check(engine.recordedCommands.isEmpty, "composition never autoplays")
            let background = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 900, height: 600),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
            background.backgroundColor = .systemTeal
            check(CGPreflightPostEventAccess(), "WindowServer event delivery is authorized")
            for queue in [false, true] {
                environment.presentation.requestQueue(queue)
                await settle()
                background.makeKeyAndOrderFront(nil)
                panel.resignKey()
                panel.orderFrontRegardless()
                try? await Task.sleep(for: .milliseconds(100))
                let point = CGPoint(x: panel.frame.maxX - 30, y: panel.frame.minY + 28)
                mouse(.leftMouseDown, at: point)
                mouse(.leftMouseUp, at: point)
                await settle()
                mouse(.mouseMoved, at: CGPoint(x: 10, y: 10))
                await settle()
                check(panel.isKeyWindow && environment.presentation.mode != .compact,
                      "blank \(queue ? "queue" : "control") panel click retains native focus")
                let origin = panel.frame.origin
                mouse(.leftMouseDown, at: point)
                mouse(.leftMouseDragged, at: CGPoint(x: point.x + 3, y: point.y))
                await settle()
                check(panel.frame.origin == origin, "background drag slop leaves the frame unchanged")
                mouse(.leftMouseDragged, at: CGPoint(x: point.x + 24, y: point.y + 16))
                mouse(.leftMouseUp, at: CGPoint(x: point.x + 24, y: point.y + 16))
                await settle()
                check(abs(panel.frame.minX - origin.x - 24) < 1 && abs(panel.frame.minY - origin.y - 16) < 1,
                      "blank \(queue ? "queue" : "control") panel drag moves the whole window")
                check(!environment.monolithWindow.isDragging && engine.recordedCommands.isEmpty,
                      "background drag balances attention without playback commands")
            }
            background.orderOut(nil)
            panel.makeKey()
            environment.presentation.requestQueue(false)
            await settle()
            let a = QueueEntry(id: "a", uri: first.uri, target: nil, track: first, metadataFailed: false)
            let b = QueueEntry(id: "b", uri: second.uri, target: nil, track: second, metadataFailed: false)
            engine.emit(.queueChanged(PlaybackQueue(generation: 1, previous: [], current: a, next: [b])))
            await settle()
            engine.emit(.queueChanged(PlaybackQueue(generation: 2, previous: [a], current: b, next: [])))
            await settle()
            check(MonolithNavigationProbe.samples.last?.0 == "b" && MonolithNavigationProbe.samples.last?.1 == .next,
                  "production next occurrence consumes next direction")
            let heart = accessibilityTree(panel.contentView!).first { attribute($0, "accessibilityLabel") as? String == "Spotify favorite" }!
            check(!booleanAction(heart, "isAccessibilityEnabled"), "queue-first metadata disables old-track favorite")
            _ = booleanAction(heart, "accessibilityPerformPress")
            await settle()
            check(await library.mutations.isEmpty, "queue-first favorite cannot mutate previous track")
            engine.emit(.trackChanged(second))
            engine.emit(.paused(positionMs: 1545))
            await settle()
            let hydratedHeart = accessibilityTree(panel.contentView!).first { attribute($0, "accessibilityLabel") as? String == "Spotify favorite" }!
            check(environment.favorite.uri == second.uri && booleanAction(hydratedHeart, "isAccessibilityEnabled"), "matching favorite becomes available")
            _ = booleanAction(hydratedHeart, "accessibilityPerformPress")
            await settle()
            check(await library.mutations.last == second.uri, "matching favorite acts on displayed track")
            engine.emit(.queueChanged(PlaybackQueue(generation: 3, previous: [], current: a, next: [b])))
            await settle()
            check(MonolithNavigationProbe.samples.last?.0 == "a" && MonolithNavigationProbe.samples.last?.1 == .previous,
                  "production reversal consumes previous direction")
            status.perform(NSSelectorFromString("toggleKeepOnTop"))
            await settle()
            check(panel.level == (environment.presentation.keepOnTop ? .floating : .normal), "keep-on-top updates native level")
            environment.presentation.requestQueue(true)
            await settle()
            check(panel.frame.height == 360, "production observer switches queue without resizing")
            panel.cancelOperation(nil)
            await settle()
            check(panel.isVisible && environment.presentation.mode == .expanded && panel.frame.height == 360, "Escape closes queue first")
            panel.cancelOperation(nil)
            await settle()
            check(!panel.isVisible && !environment.presentation.isVisible, "second Escape hides panel")
            status.perform(NSSelectorFromString("handleClick"))
            await settle()
            check(panel.isVisible && panel.isKeyWindow && environment.presentation.mode == .expanded, "status item reopens focused sleeve")
            player.stop()
            print(failures.isEmpty ? "MONOLITH COMPOSITION PASS" : "MONOLITH COMPOSITION FAIL")
            if !failures.isEmpty { exit(1) }
            withExtendedLifetime(status) { app.terminate(nil) }
        }
        app.run()
    }

    @MainActor static func attribute(_ value: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        guard value.responds(to: selector) else { return nil }
        return value.perform(selector)?.takeUnretainedValue()
    }
    @MainActor static func mouse(_ type: CGEventType, at point: CGPoint) {
        let height = NSScreen.screens.first!.frame.maxY
        CGEvent(mouseEventSource: nil, mouseType: type,
                mouseCursorPosition: CGPoint(x: point.x, y: height - point.y), mouseButton: .left)!
            .post(tap: .cghidEventTap)
    }
    @MainActor static func booleanAction(_ value: NSObject, _ name: String) -> Bool {
        let selector = NSSelectorFromString(name)
        precondition(value.responds(to: selector), "missing accessibility method \(name)")
        typealias Action = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(value.method(for: selector), to: Action.self)(value, selector)
    }
    @MainActor static func accessibilityTree(_ value: Any) -> [NSObject] {
        guard let element = value as? NSObject else { return [] }
        return [element] + ((attribute(element, "accessibilityChildren") as? [Any]) ?? []).flatMap { accessibilityTree($0) }
    }
}
