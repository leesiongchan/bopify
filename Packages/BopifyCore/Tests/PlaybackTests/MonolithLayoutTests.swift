import Foundation
import Testing
@testable import BopifyPlayback

@Suite("Monolith layout")
struct MonolithLayoutTests {
    let available = CGSize(width: 1440, height: 900)

    @Test func recordSizesAndFixedQueueTransport() {
        let rest = monolithLayout(mode: .compact, availableSize: available)
        let focus = monolithLayout(mode: .expanded, availableSize: available)
        let queue = monolithLayout(mode: .queue, availableSize: available)
        #expect(rest.recordDiameter == 118)
        #expect(rest.contentSize == CGSize(width: 142, height: 142))
        #expect(focus.recordDiameter == 182)
        #expect(focus.contentSize == CGSize(width: 484, height: 264))
        #expect(queue.contentSize == CGSize(width: 484, height: 424))
        #expect(focus.recordCenter == queue.recordCenter)
        #expect(focus.controlsFrame == queue.controlsFrame)
    }

    @Test(arguments: [PlayerMode.compact, .expanded, .queue])
    func appKitAnchorUsesInvertedLocalY(_ mode: PlayerMode) {
        let layout = monolithLayout(mode: mode, availableSize: available)
        let anchor = CGPoint(x: 400, y: 500)
        let frame = monolithFrame(recordCenter: anchor, layout: layout,
                                  visibleFrame: CGRect(origin: .zero, size: available))
        #expect(abs(frame.minX + layout.recordCenter.x - anchor.x) < 0.5)
        #expect(abs(frame.maxY - layout.recordCenter.y - anchor.y) < 0.5)
    }

    @Test func clampedAnchorSurvivesCollapse() {
        let screen = CGRect(origin: .zero, size: available)
        let focused = monolithLayout(mode: .expanded, availableSize: available)
        let frame = monolithFrame(recordCenter: CGPoint(x: 1430, y: 10), layout: focused, visibleFrame: screen)
        #expect(screen.contains(frame))
        let adjusted = CGPoint(x: frame.minX + focused.recordCenter.x, y: frame.maxY - focused.recordCenter.y)
        let rest = monolithLayout(mode: .compact, availableSize: available)
        let collapsed = monolithFrame(recordCenter: adjusted, layout: rest, visibleFrame: screen)
        #expect(collapsed.midX == adjusted.x)
        #expect(collapsed.midY == adjusted.y)
    }

    @Test func narrowNegativeScreenKeepsControlsReachable() {
        let screen = CGRect(x: -800, y: 100, width: 320, height: 480)
        let focused = monolithLayout(mode: .expanded, availableSize: screen.size)
        let queue = monolithLayout(mode: .queue, availableSize: screen.size)
        let frame = monolithFrame(recordCenter: CGPoint(x: 4000, y: -100), layout: queue, visibleFrame: screen)
        #expect(screen.contains(frame))
        #expect(queue.recordDiameter == 118)
        #expect(queue.controlsFrame == focused.controlsFrame)
        #expect(CGRect(origin: .zero, size: queue.contentSize).contains(queue.controlsFrame))
        #expect(CGRect(origin: .zero, size: queue.contentSize).contains(queue.queueFrame))
        #expect(queue.controlsFrame.width >= 144)
        #expect(queue.controlsFrame.height >= 216)
    }

    @Test func invalidAnchorHasFiniteFallback() {
        let layout = monolithLayout(mode: .expanded, availableSize: available)
        let frame = monolithFrame(recordCenter: CGPoint(x: CGFloat.nan, y: CGFloat.infinity), layout: layout,
                                  visibleFrame: CGRect(origin: .zero, size: available))
        #expect(frame.origin.x.isFinite && frame.origin.y.isFinite)
    }

    @Test func queueShrinksBeforeMovingTransport() {
        let available = CGSize(width: 600, height: 300)
        let focused = monolithLayout(mode: .expanded, availableSize: available)
        let queue = monolithLayout(mode: .queue, availableSize: available)
        #expect(queue.contentSize.height == 300)
        #expect(focused.controlsFrame == queue.controlsFrame)
        #expect(focused.recordCenter == queue.recordCenter)
    }
}
