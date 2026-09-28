import SwiftUI
import BopifyDomain
import BopifyLibrary
import BopifyPlayback

@main struct MonolithRefinementProbe {
    actor Library: LibraryService, SavedTracksService {
        private(set) var pageOffsets: [Int] = []
        func savedState(for uri: SpotifyURI) async throws -> Bool { false }
        func save(_ uri: SpotifyURI) async throws {}
        func remove(_ uri: SpotifyURI) async throws {}
        func savedTracks(offset: Int, limit: Int) async throws -> SavedTracksPage {
            pageOffsets.append(offset)
            return SavedTracksPage(tracks: (offset..<min(60, offset + limit)).map { index in
                Track(uri: SpotifyURI("spotify:track:liked\(index)")!,
                      title: "Liked song \(index) with a deliberately long title", artists: [ArtistSummary(name: "Artist")],
                      albumTitle: "Shared album", artwork: index.isMultiple(of: 3) ? nil : Artwork(url: URL(string: "https://preview.invalid/sample/1")!), durationMs: 240_000)
            }, nextOffset: offset == 0 ? 50 : nil, total: 60)
        }
    }
    @MainActor static func main() {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        guard session?["CGSSessionScreenIsLocked"] as? Bool != true else {
            print("BLOCKED: unlock macOS for native refinement input checks")
            exit(77)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)
        Task { @MainActor in
            let engine = StubPlaybackEngine()
            let player = PlayerModel(engine: engine)
            player.start()
            let library = Library()
            let environment = AppEnvironment(previewPlayer: player, favoriteService: library, savedTracksService: library)
            let controller = StatusItemController(content: MiniPlayerView(environment: environment), environment: environment)
            controller.perform(NSSelectorFromString("handleClick"))
            engine.emit(.trackChanged(Track(uri: SpotifyURI("spotify:track:playing")!, title: "Playing", artists: [], albumTitle: nil, artwork: nil, durationMs: 240_000)))
            engine.emit(.paused(positionMs: 30_000))
            await settle()
            let panel = app.windows.compactMap { $0 as? StatusPanel }.first!
            let layout = environment.monolithWindow.layout
            precondition(environment.likedSongs.tracks.count == 50)
            let center = CGPoint(x: layout.lowerFrame.midX, y: layout.lowerFrame.minY + 58)
            await click(CGPoint(x: center.x + 44, y: center.y), panel)
            precondition(environment.likedSongs.selectedURI?.rawValue == "spotify:track:liked1", "side cover centers")
            precondition(engine.recordedCommands.isEmpty, "centering cannot play")
            mouse(.leftMouseDown, center, panel)
            await settle(40)
            mouse(.leftMouseDragged, CGPoint(x: center.x - 60, y: center.y), panel)
            await settle(40)
            mouse(.leftMouseUp, CGPoint(x: center.x - 60, y: center.y), panel)
            await settle(350)
            precondition(engine.recordedCommands.isEmpty, "drag starting on center cannot play")
            let afterDrag = environment.likedSongs.selectedURI
            key(124)
            await settle(350)
            precondition(environment.likedSongs.selectedURI != afterDrag, "arrow belongs to focused Cover Flow")
            precondition(engine.recordedCommands.isEmpty, "arrow browsing cannot seek")
            // The speaker is immediately before Queue in the bottom control row.
            let volume = accessibilityTree(panel.contentView!).first { attribute($0, "accessibilityLabel") as? String == "Volume" }!
            let frameSelector = NSSelectorFromString("accessibilityFrame")
            typealias FrameGetter = @convention(c) (AnyObject, Selector) -> CGRect
            let frameGetter = unsafeBitCast(volume.method(for: frameSelector), to: FrameGetter.self)
            let frame = frameGetter(volume, frameSelector)
            clickScreen(CGPoint(x: frame.midX, y: NSScreen.screens[0].frame.maxY - frame.midY))
            await settle(350)
            let sliders = app.windows.flatMap { descendants($0.contentView) }.compactMap { $0 as? NSSlider }
            let slider = sliders.first { $0.isVertical }!
            precondition(slider.bounds.height > slider.bounds.width, "volume slider is vertical")
            key(53)
            await settle(350)
            precondition(environment.presentation.activePopover == nil, "Escape closes volume first")
            await click(CGPoint(x: center.x + 44, y: center.y), panel)
            let selected = environment.likedSongs.selectedURI!
            key(36)
            await settle(350)
            precondition(engine.recordedCommands.filter { $0.hasPrefix("load:") } == ["load:" + selected.rawValue], "Return plays the selected track exactly once")
            print("MONOLITH REFINEMENT PASS")
            await environment.prepareForQuit()
            app.terminate(nil)
        }
        app.run()
    }
    @MainActor static func settle(_ milliseconds: Int = 900) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }
    @MainActor static func click(_ point: CGPoint, _ panel: NSWindow) async {
        mouse(.leftMouseDown, point, panel); await settle(40)
        mouse(.leftMouseUp, point, panel); await settle(350)
    }
    @MainActor static func mouse(_ type: CGEventType, _ point: CGPoint, _ panel: NSWindow) {
        let screen = panel.convertPoint(toScreen: CGPoint(x: point.x, y: panel.frame.height - point.y))
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: CGPoint(x: screen.x, y: NSScreen.screens[0].frame.maxY - screen.y), mouseButton: .left)?.post(tap: .cghidEventTap)
    }
    @MainActor static func clickScreen(_ point: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }
    static func key(_ code: CGKeyCode) {
        CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)?.post(tap: .cghidEventTap)
    }
    @MainActor static func descendants(_ view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return [view] + view.subviews.flatMap { descendants($0) }
    }
    @MainActor static func attribute(_ value: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        guard value.responds(to: selector) else { return nil }
        return value.perform(selector)?.takeUnretainedValue()
    }
    @MainActor static func accessibilityTree(_ value: Any) -> [NSObject] {
        guard let element = value as? NSObject else { return [] }
        return [element] + ((attribute(element, "accessibilityChildren") as? [Any]) ?? []).flatMap { accessibilityTree($0) }
    }
}
