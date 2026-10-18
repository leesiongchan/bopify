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
    @Test func radialProgressStartsAtTopAndRunsClockwise() {
        #expect(radialProgress(x: 0, y: -1) == 0)
        #expect(radialProgress(x: 1, y: 0) == 0.25)
        #expect(radialProgress(x: 0, y: 1) == 0.5)
        #expect(radialProgress(x: -1, y: 0) == 0.75)
        #expect(radialProgress(x: 0, y: 0) == nil)
        #expect(radialProgress(x: .infinity, y: 1) == nil)
    }
    @Test func crossingTopDoesNotJumpBetweenStartAndEnd() {
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
        presentation.sendAttention(.visibility(true))
        presentation.sendAttention(.pointer(true))
        presentation.requestQueue(true)
        #expect(presentation.dismissQueue())
        #expect(presentation.mode == .expanded)
        #expect(!presentation.dismissQueue())
        presentation.sendAttention(.pointer(false))
        presentation.advanceAttention(to: ProcessInfo.processInfo.systemUptime + 1)
        #expect(!presentation.dismissQueue())
        #expect(presentation.mode == .compact)
        presentation.resetEngagement()
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

    private func track() -> Track {
        Track(uri: SpotifyURI("spotify:track:t")!, title: "T", artists: [], albumTitle: nil, artwork: nil, durationMs: 1)
    }
    @Test func aTrackAlwaysShowsThePlayer() {
        var state = PlaybackState()
        state.currentTrack = track()
        #expect(PlayerContent(state) == .player)
        state.startup = .resolved(.nothing)
        #expect(PlayerContent(state) == .player)
    }
    @Test func startupLoadsInsteadOfOfferingThePasteView() {
        var state = PlaybackState()
        #expect(PlayerContent(state) == .loading)
        // Restored or Liked Songs may be reported before the engine's Loading event.
        state.startup = .resolved(.restored)
        #expect(PlayerContent(state) == .loading)
        state.startup = .resolved(.likedSongs)
        #expect(PlayerContent(state) == .loading)
    }
    @Test func onlyANothingOutcomeOffersThePasteView() {
        var state = PlaybackState()
        state.startup = .resolved(.nothing)
        #expect(PlayerContent(state) == .chooseContext)
        state.phase = .loading
        #expect(PlayerContent(state) == .loading)
    }
    @Test func aRemoteOutcomeNamesTheDevice() {
        var state = PlaybackState()
        state.startup = .resolved(.remote(deviceName: "iPhone"))
        #expect(PlayerContent(state) == .remote(deviceName: "iPhone"))
    }
    @Test func errorsSurfaceEvenWhileStartupIsPending() {
        var state = PlaybackState()
        state.phase = .error(.playbackSessionLost)
        #expect(PlayerContent(state) == .player)
    }
    @Test func aNothingOutcomeOutsideIdleKeepsThePlayer() {
        var state = PlaybackState()
        state.startup = .resolved(.nothing)
        state.phase = .paused
        #expect(PlayerContent(state) == .player)
    }
    @Test func errorsSurfaceOverARemoteOutcome() {
        var state = PlaybackState()
        state.startup = .resolved(.remote(deviceName: "iPhone"))
        state.phase = .error(.playbackSessionLost)
        #expect(PlayerContent(state) == .player)
    }

    private func remote(isPlaying: Bool) -> RemotePlayback {
        RemotePlayback(deviceName: "iPhone", trackURI: SpotifyURI("spotify:track:r")!, track: nil,
                       isPlaying: isPlaying, positionMs: 0, durationMs: 1)
    }
    @Test func anInactiveStatusNamesTheMirroredDeviceOrSaysNothingPlays() {
        var state = PlaybackState()
        #expect(InactiveStatus(state) == .notPlaying)
        state.remote = remote(isPlaying: true)
        #expect(InactiveStatus(state) == .playingOn(deviceName: "iPhone"))
        state.remote = remote(isPlaying: false)
        #expect(InactiveStatus(state) == .pausedOn(deviceName: "iPhone"))
        // A stale mirror's device has stopped, so it is not named.
        state.remote = nil
        state.staleRemote = remote(isPlaying: false)
        #expect(InactiveStatus(state) == .notPlaying)
    }
    @MainActor @Test func popoverSwitchKeepsAttention() {
        let presentation = PlayerPresentation()
        presentation.isVisible = true
        presentation.sendAttention(.pointer(true))
        presentation.presentPopover(.favorite)
        presentation.presentPopover(.volume)
        presentation.sendAttention(.pointer(false))
        presentation.sendAttention(.keyboardFocus(false))
        presentation.advanceAttention(to: ProcessInfo.processInfo.systemUptime + 1)
        #expect(presentation.activePopover == .volume && presentation.mode == .expanded)
        presentation.sendAttention(.interaction(.volume, true))
        #expect(presentation.dismissPopover())
        presentation.advanceAttention(to: ProcessInfo.processInfo.systemUptime + 1)
        #expect(presentation.mode == .expanded)
        presentation.sendAttention(.interaction(.volume, false))
        presentation.advanceAttention(to: ProcessInfo.processInfo.systemUptime + 1)
        #expect(presentation.mode == .compact)
        #expect(!presentation.dismissPopover())
    }
    @MainActor @Test func hidingAndResetClearPopoverOwnership() {
        let presentation = PlayerPresentation()
        presentation.isVisible = true
        presentation.presentPopover(.volume)
        presentation.isVisible = false
        #expect(presentation.activePopover == nil)
        presentation.isVisible = true
        #expect(presentation.mode == .compact)
        presentation.presentPopover(.favorite)
        presentation.resetEngagement()
        #expect(presentation.activePopover == nil)
    }

}
