import Foundation
import Testing
@testable import BopifyPlayback

@Suite("Player attention")
struct PlayerAttentionTests {
    @Test func hoverRevealsAndDisengagementWaits280ms() {
        var state = PlayerAttentionState()
        state.update(.visibility(true), at: 0)
        #expect(!state.isRevealed)
        state.update(.pointer(true), at: 0)
        #expect(state.isRevealed)
        state.update(.pointer(false), at: 1)
        #expect(state.collapseDeadline == 1.280)
        state.advance(to: 1.279)
        #expect(state.isRevealed)
        state.advance(to: 1.281)
        #expect(!state.isRevealed)
    }

    @Test func returningPointerInvalidatesOldDeadline() {
        var state = PlayerAttentionState()
        state.update(.visibility(true), at: 0)
        state.update(.pointer(true), at: 0)
        state.update(.pointer(false), at: 1)
        state.update(.pointer(true), at: 1.1)
        state.advance(to: 1.3)
        #expect(state.isRevealed)
        #expect(state.collapseDeadline == nil)
    }

    @Test(arguments: [PlayerAttentionEvent.keyboardFocus(true), .accessibilityFocus(true)])
    func focusRetainsControlsAfterThePointerLeaves(_ event: PlayerAttentionEvent) {
        var state = PlayerAttentionState()
        state.update(.visibility(true), at: 0)
        state.update(.pointer(true), at: 0)
        state.update(event, at: 0.1)
        state.update(.pointer(false), at: 1)
        state.advance(to: 100)
        #expect(state.isRevealed)
        #expect(state.collapseDeadline == nil)
    }

    @Test func pointerRetainsControlsAfterFocusLeaves() {
        var state = PlayerAttentionState()
        state.update(.visibility(true), at: 0)
        state.update(.keyboardFocus(true), at: 0)
        state.update(.pointer(true), at: 0)
        state.update(.keyboardFocus(false), at: 1)
        state.advance(to: 100)
        #expect(state.isRevealed)
        state.update(.pointer(false), at: 101)
        state.advance(to: 101.281)
        #expect(!state.isRevealed)
    }

    @Test(arguments: [PlayerInteraction.seek, .volume, .windowDrag, .popover, .menu])
    func interactionsHoldUntilReleased(_ interaction: PlayerInteraction) {
        var state = PlayerAttentionState()
        state.update(.visibility(true), at: 0)
        state.update(.interaction(interaction, true), at: 0)
        state.advance(to: 100)
        #expect(state.isRevealed)
        state.update(.interaction(interaction, false), at: 101)
        state.advance(to: 101.279)
        #expect(state.isRevealed)
        state.advance(to: 101.281)
        #expect(!state.isRevealed)
    }

    @Test func overlappingHoldsReleaseIndependently() {
        var state = PlayerAttentionState()
        state.update(.visibility(true), at: 0)
        state.update(.interaction(.seek, true), at: 0)
        state.update(.interaction(.popover, true), at: 0)
        state.update(.interaction(.seek, false), at: 1)
        state.advance(to: 100)
        #expect(state.isRevealed)
        state.update(.interaction(.popover, false), at: 101)
        state.advance(to: 101.281)
        #expect(!state.isRevealed)
    }

    @Test func hiddenPanelClearsEveryHold() {
        var state = PlayerAttentionState()
        state.update(.visibility(true), at: 0)
        state.update(.keyboardFocus(true), at: 0)
        state.update(.accessibilityFocus(true), at: 0)
        state.update(.pointer(true), at: 0)
        state.update(.interaction(.popover, true), at: 0)
        state.update(.visibility(false), at: 1)
        state.update(.interaction(.popover, false), at: 2)
        #expect(!state.isRevealed)
        #expect(state.collapseDeadline == nil)
        state.update(.visibility(true), at: 3)
        state.advance(to: 100)
        #expect(!state.isRevealed)
    }

    @Test func resettingCancelsTheDeadline() {
        var state = PlayerAttentionState()
        state.update(.visibility(true), at: 0)
        state.update(.pointer(true), at: 0)
        state.update(.pointer(false), at: 1)
        state.update(.reset, at: 1.1)
        #expect(!state.isRevealed)
        #expect(state.collapseDeadline == nil)
    }

    @Test func repeatedExitDoesNotExtendTheDeadline() {
        var state = PlayerAttentionState()
        state.update(.visibility(true), at: 0)
        state.update(.pointer(true), at: 0)
        state.update(.pointer(false), at: 1)
        state.update(.pointer(false), at: 1.2)
        state.advance(to: 1.281)
        #expect(!state.isRevealed)
    }

    @MainActor @Test func queueResetsAfterFullCollapse() {
        let presentation = PlayerPresentation()
        presentation.sendAttention(.visibility(true))
        presentation.sendAttention(.pointer(true))
        presentation.requestQueue(true)
        #expect(presentation.mode == .queue)
        presentation.sendAttention(.pointer(false))
        presentation.advanceAttention(to: ProcessInfo.processInfo.systemUptime + 1)
        #expect(presentation.mode == .compact)
        presentation.sendAttention(.pointer(true))
        #expect(presentation.mode == .expanded)
        presentation.resetEngagement()
    }
}
