import Foundation
import CoreGraphics
import Testing
import BopifyDomain
@testable import BopifyPlayback

@Suite("Player presentation")
struct PlayerPresentationTests {
    private func entry(_ id: String) -> QueueEntry {
        QueueEntry(id: id, uri: SpotifyURI("spotify:track:same"), target: nil, track: nil, metadataFailed: false)
    }
    @Test func confirmedOccurrencesDetermineDirection() {
        let first = PlaybackQueue(generation: 1, previous: [entry("p")], current: entry("a"), next: [entry("b")])
        let second = PlaybackQueue(generation: 2, previous: [entry("a")], current: entry("b"), next: [])
        #expect(carouselDirection(old: first, new: second) == .next)
        #expect(carouselDirection(old: second, new: first) == .previous)
    }
    @Test func ambiguousDuplicateReplacementFades() {
        let old = PlaybackQueue(generation: 1, previous: [], current: entry("a"), next: [entry("b")])
        let replacement = PlaybackQueue(generation: 2, previous: [], current: entry("x"), next: [entry("y")])
        #expect(carouselDirection(old: old, new: replacement) == .fade)
        #expect(carouselDirection(old: nil, new: replacement) == .fade)
    }
    @Test func radialProgressStartsAtTwelveAndRunsClockwise() {
        #expect(radialProgress(x: 0, y: -1) == 0)
        #expect(radialProgress(x: 1, y: 0) == 0.25)
        #expect(radialProgress(x: 0, y: 1) == 0.5)
        #expect(radialProgress(x: -1, y: 0) == 0.75)
        #expect(radialProgress(x: 0, y: 0) == nil)
        #expect(radialProgress(x: .infinity, y: 1) == nil)
    }
    @Test func crossingTwelveDoesNotJumpBetweenStartAndEnd() {
        var end = RadialScrub(start: 0.99)
        end.update(0.01)
        #expect(end.progress == 1)
        var start = RadialScrub(start: 0.01)
        start.update(0.99)
        #expect(start.progress == 0)
    }
    @Test func invalidDurationDisablesSeekAndValidProgressClamps() {
        #expect(seekPosition(progress: 0.5, durationMs: 0) == nil)
        #expect(seekPosition(progress: .nan, durationMs: 1000) == nil)
        #expect(seekPosition(progress: -1, durationMs: 1000) == 0)
        #expect(seekPosition(progress: 2, durationMs: 1000) == 1000)
        #expect(seekPosition(progress: 0.5, durationMs: 1) == 1)
    }

    @MainActor @Test func escapeReturnsFromQueueBeforeHiding() {
        let presentation = PlayerPresentation()
        presentation.setMode(.queue)
        #expect(presentation.dismissQueue())
        #expect(presentation.mode == .expanded)
        #expect(!presentation.dismissQueue())
        presentation.setMode(.compact)
        #expect(!presentation.dismissQueue())
        #expect(presentation.mode == .compact)
    }

    @Test func windowClampsInsideVisibleScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let frame = clampedPlayerFrame(origin: CGPoint(x: 950, y: 650), size: CGSize(width: 410, height: 560), visibleFrame: screen)
        #expect(screen.contains(frame))
        #expect(frame.size == CGSize(width: 410, height: 560))
    }
    @Test func removedAndSmallScreensRetainAReachableWindow() {
        let screen = CGRect(x: -800, y: 100, width: 320, height: 480)
        let frame = clampedPlayerFrame(origin: CGPoint(x: 5000, y: -900), size: CGSize(width: 410, height: 560), visibleFrame: screen)
        #expect(frame == screen)
        let invalid = clampedPlayerFrame(origin: CGPoint(x: CGFloat.nan, y: CGFloat.infinity), size: CGSize(width: 200, height: 88), visibleFrame: screen)
        #expect(screen.contains(invalid))
    }

}
