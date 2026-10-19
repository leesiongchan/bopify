import Foundation
import Testing
@testable import BopifyPlayback

@Suite("Record layout")
struct RecordLayoutTests {
    let available = CGSize(width: 1440, height: 900)

    @Test(arguments: [PlayerMode.expanded, .queue])
    func lyricsFitBelowTheShelfWithoutMovingTransport(_ mode: PlayerMode) {
        let original = recordLayout(mode: mode, availableSize: available)
        let lyrics = recordLayout(mode: mode, availableSize: available, showsLyrics: true)
        #expect(lyrics.controlsFrame == original.controlsFrame)
        #expect(lyrics.lowerFrame == original.lowerFrame)
        #expect(lyrics.lyricsFrame.minY >= original.contentSize.height)
        #expect(CGRect(origin: .zero, size: lyrics.contentSize).contains(lyrics.lyricsFrame))
    }

    @Test func collapsedLyricsContainTheirVinylHandleWithinTheSharedSurface() {
        let layout = recordLayout(mode: .compact, availableSize: available, showsLyrics: true)
        #expect(layout.controlsFrame.isEmpty && layout.lowerFrame.isEmpty)
        #expect(layout.recordDiameter <= 36)
        #expect(!layout.lyricsFrame.isEmpty)
        #expect(layout.sleeveFrame.contains(layout.lyricsFrame))
        #expect(layout.lyricsFrame.contains(CGRect(x: layout.recordCenter.x - layout.recordDiameter / 2,
            y: layout.recordCenter.y - layout.recordDiameter / 2, width: layout.recordDiameter, height: layout.recordDiameter)))
        #expect(layout.contentSize.height < 180)
    }

    @Test func lyricsShareThePlayerSurfaceWithNoGap() {
        let layout = recordLayout(mode: .expanded, availableSize: available, showsLyrics: true)
        #expect(layout.sleeveFrame.contains(layout.lyricsFrame))
        #expect(layout.lyricsFrame.minY == 360)
        #expect(layout.sleeveFrame.maxY == layout.lyricsFrame.maxY)
    }

    @Test(arguments: [CGSize(width: 320, height: 480), CGSize(width: 484, height: 300)])
    func lyricsAndControlsRemainReachableOnSmallScreens(_ size: CGSize) {
        let layout = recordLayout(mode: .expanded, availableSize: size, showsLyrics: true)
        let bounds = CGRect(origin: .zero, size: layout.contentSize)
        #expect(layout.contentSize.height <= size.height)
        #expect(bounds.contains(layout.controlsFrame))
        #expect(bounds.contains(layout.lyricsFrame))
        #expect(!layout.lyricsFrame.intersects(layout.controlsFrame))
        #expect(!layout.lyricsFrame.intersects(layout.lowerFrame))
        #expect(layout.recordCenter.y - layout.recordDiameter / 2 >= 0)
        #expect(layout.recordCenter.y + layout.recordDiameter / 2 <= layout.lyricsFrame.minY)
    }

    @Test(arguments: [CGSize(width: 484, height: 480), CGSize(width: 320, height: 480), CGSize(width: 484, height: 300)])
    func engagedModesShareGeometry(_ size: CGSize) {
        let expanded = recordLayout(mode: .expanded, availableSize: size)
        let queue = recordLayout(mode: .queue, availableSize: size)
        #expect(expanded.contentSize == queue.contentSize)
        #expect(expanded.recordCenter == queue.recordCenter)
        #expect(expanded.controlsFrame == queue.controlsFrame)
        #expect(expanded.lowerFrame == queue.lowerFrame)
        #expect(expanded.lowerFrame.height >= 80)
        #expect(!expanded.controlsFrame.intersects(expanded.lowerFrame))
    }

    @Test func recordSizesAndFixedQueueTransport() {
        let rest = recordLayout(mode: .compact, availableSize: available)
        let focus = recordLayout(mode: .expanded, availableSize: available)
        let queue = recordLayout(mode: .queue, availableSize: available)
        #expect(rest.recordDiameter == 118)
        #expect(rest.contentSize == CGSize(width: 142, height: 142))
        #expect(focus.recordDiameter == 182)
        #expect(focus.contentSize == CGSize(width: 484, height: 360))
        #expect(queue.contentSize == CGSize(width: 484, height: 360))
        #expect(focus.recordCenter == queue.recordCenter)
        #expect(focus.controlsFrame == queue.controlsFrame)
    }

    @Test func restingSleeveIsADiscBehindTheRecord() {
        let rest = recordLayout(mode: .compact, availableSize: available)
        let radius = rest.recordDiameter / 2
        #expect(rest.sleeveFrame == CGRect(x: rest.recordCenter.x - radius, y: rest.recordCenter.y - radius,
                                           width: rest.recordDiameter, height: rest.recordDiameter))
        #expect(rest.sleeveCornerRadius == radius)
        #expect(rest.controlsFrame == CGRect(origin: rest.recordCenter, size: .zero))
        #expect(rest.lowerFrame == CGRect(origin: rest.recordCenter, size: .zero))
        #expect(recordLayout(mode: .expanded, availableSize: available).sleeveCornerRadius == 28)
    }

    @Test(arguments: [PlayerMode.compact, .expanded, .queue])
    func appKitAnchorUsesInvertedLocalY(_ mode: PlayerMode) {
        let layout = recordLayout(mode: mode, availableSize: available)
        let anchor = CGPoint(x: 400, y: 500)
        let frame = playerWindowFrame(recordCenter: anchor, layout: layout,
                                  visibleFrame: CGRect(origin: .zero, size: available))
        #expect(abs(frame.minX + layout.recordCenter.x - anchor.x) < 0.5)
        #expect(abs(frame.maxY - layout.recordCenter.y - anchor.y) < 0.5)
    }

    @Test func clampedAnchorSurvivesCollapse() {
        let screen = CGRect(origin: .zero, size: available)
        let focused = recordLayout(mode: .expanded, availableSize: available)
        let frame = playerWindowFrame(recordCenter: CGPoint(x: 1430, y: 10), layout: focused, visibleFrame: screen)
        #expect(screen.contains(frame))
        let adjusted = CGPoint(x: frame.minX + focused.recordCenter.x, y: frame.maxY - focused.recordCenter.y)
        let rest = recordLayout(mode: .compact, availableSize: available)
        let collapsed = playerWindowFrame(recordCenter: adjusted, layout: rest, visibleFrame: screen)
        #expect(collapsed.midX == adjusted.x)
        #expect(collapsed.midY == adjusted.y)
    }

    @Test func narrowNegativeScreenKeepsControlsReachable() {
        let screen = CGRect(x: -800, y: 100, width: 320, height: 480)
        let focused = recordLayout(mode: .expanded, availableSize: screen.size)
        let queue = recordLayout(mode: .queue, availableSize: screen.size)
        let frame = playerWindowFrame(recordCenter: CGPoint(x: 4000, y: -100), layout: queue, visibleFrame: screen)
        #expect(screen.contains(frame))
        #expect(queue.recordDiameter == 118)
        #expect(queue.controlsFrame == focused.controlsFrame)
        #expect(CGRect(origin: .zero, size: queue.contentSize).contains(queue.controlsFrame))
        #expect(CGRect(origin: .zero, size: queue.contentSize).contains(queue.lowerFrame))
        #expect(queue.controlsFrame.width >= 144)
        #expect(queue.controlsFrame.height >= 176)
    }

    @Test func invalidAnchorHasFiniteFallback() {
        let layout = recordLayout(mode: .expanded, availableSize: available)
        let frame = playerWindowFrame(recordCenter: CGPoint(x: CGFloat.nan, y: CGFloat.infinity), layout: layout,
                                  visibleFrame: CGRect(origin: .zero, size: available))
        #expect(frame.origin.x.isFinite && frame.origin.y.isFinite)
    }

    @Test func queueShrinksBeforeMovingTransport() {
        let available = CGSize(width: 600, height: 300)
        let focused = recordLayout(mode: .expanded, availableSize: available)
        let queue = recordLayout(mode: .queue, availableSize: available)
        #expect(queue.contentSize.height == 300)
        #expect(focused.controlsFrame == queue.controlsFrame)
        #expect(focused.recordCenter == queue.recordCenter)
    }
}
