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
        controller.focusForReading()
        #expect(controller.panel.canBecomeKey)
        model.completeLoad(.timed(try lyricTestDocument()), token: model.beginLoad())
        model.holdText()
        controller.hide()
        #expect(!model.isVisible && !model.isHeld)
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
}
#endif
