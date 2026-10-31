import Foundation
import Testing
import BopifyDomain
@testable import BopifyLibrary

@Suite("RecentsModel") @MainActor
struct RecentsModelTests {
    private let album = SpotifyURI("spotify:album:alb")!
    private let playlist = SpotifyURI("spotify:playlist:pl")!
    private func play(_ id: String, _ context: SpotifyURI? = nil) -> RecentPlay {
        RecentPlay(track: testTrack(id), contextURI: context)
    }

    @Test func fiftyDistinctPlaysRemainAvailableAndRepeatsCanProduceTwelveSongs() async {
        let history = FakeHistory()
        let clock = TestClock()
        await history.setPlays(.success((0..<50).map { play("song\($0)") }))
        let model = RecentsModel(service: history, now: { clock.date })
        await model.reveal(at: clock.date)
        #expect(model.tracks.count == 50)
        model.select(testTrack("song49").uri)
        #expect(model.selectedURI == testTrack("song49").uri)

        clock.advance(60)
        await history.setPlays(.success((0..<50).map { play("song\($0 % 12)") }))
        await model.reveal(at: clock.date)
        #expect(model.tracks.count == 12)
    }

    @Test func collapsesRepeatsToTheNewestPlayAndItsContext() async {
        let history = FakeHistory()
        await history.setPlays(.success([play("a", album), play("b"), play("a", playlist), play("c")]))
        let model = RecentsModel(service: history)
        await model.reveal(at: Date())
        #expect(model.tracks.map(\.uri.rawValue) == ["spotify:track:a", "spotify:track:b", "spotify:track:c"])
        #expect(model.selectedURI == testTrack("a").uri)
        #expect(model.playRequest(for: testTrack("a")) == PlayRequest(contextURI: album, startTrackURI: testTrack("a").uri))
        #expect(model.playRequest(for: testTrack("b")) == PlayRequest(contextURI: testTrack("b").uri))
    }

    @Test func reloadsAtMostOncePerMinuteAndKeepsAPresentSelection() async {
        let history = FakeHistory()
        let clock = TestClock()
        await history.setPlays(.success([play("a"), play("b")]))
        let model = RecentsModel(service: history, now: { clock.date })
        await model.reveal(at: clock.date)
        model.select(testTrack("b").uri)
        model.hide(at: clock.date)
        clock.advance(59)
        await history.setPlays(.success([play("c"), play("b")]))
        await model.reveal(at: clock.date)
        #expect(await history.recentCalls == 1)
        clock.advance(1)
        await model.reveal(at: clock.date)
        #expect(await history.recentCalls == 2)
        #expect(model.selectedURI == testTrack("b").uri)
        clock.advance(60)
        await history.setPlays(.success([play("c")]))
        await model.reveal(at: clock.date)
        #expect(model.selectedURI == testTrack("c").uri)
    }

    @Test func aRateLimitWaitsForItsDeadline() async {
        let history = FakeHistory()
        let clock = TestClock()
        await history.setPlays(.failure(.rateLimited(retryAfterSeconds: 30)))
        let model = RecentsModel(service: history, now: { clock.date })
        await model.reveal(at: clock.date)
        #expect(model.error == .rateLimited(retryAfterSeconds: 30))
        #expect(model.retryAfter == clock.date.addingTimeInterval(30))
        await model.retry(at: clock.date.addingTimeInterval(10))
        #expect(await history.recentCalls == 1)
        await history.setPlays(.success([play("a")]))
        await model.retry(at: clock.date.addingTimeInterval(30))
        #expect(model.error == nil && model.tracks.count == 1)
    }

    /// A quick tab round trip can hide the old view after the new one revealed; the model must stay shown.
    @Test func staysShownWhileAnyRevealIsUnmatched() async {
        let history = FakeHistory()
        await history.setPlays(.failure(.unavailable))
        let model = RecentsModel(service: history)
        await model.reveal(at: Date())
        await model.reveal(at: Date())
        model.hide(at: Date())
        await history.setPlays(.success([play("a")]))
        await model.retry(at: Date())
        #expect(model.error == nil && model.tracks.count == 1)
    }

    @Test func clearedLibraryReloadsOnReveal() async {
        let history = FakeHistory()
        await history.setPlays(.success([play("a")]))
        let model = RecentsModel(service: history)
        await model.reveal(at: Date())
        model.clear()
        await model.reveal(at: Date())
        #expect(await history.recentCalls == 2)
        #expect(model.tracks.count == 1)
    }

    @Test func clearForgetsEverything() async {
        let history = FakeHistory()
        await history.setPlays(.success([play("a", album)]))
        let model = RecentsModel(service: history)
        await model.reveal(at: Date())
        model.clear()
        #expect(model.tracks.isEmpty && model.selectedURI == nil)
        #expect(model.playRequest(for: testTrack("a")) == PlayRequest(contextURI: testTrack("a").uri))
    }

    @Test(arguments: [false, true])
    func inFlightLoadSurvivesViewCancellationButNotLibraryClear(clear: Bool) async {
        let history = FakeHistory()
        await history.setPlays(.success([play("a")]))
        await history.holdNextRecent()
        let model = RecentsModel(service: history)
        let loading = Task { await model.reveal(at: Date()) }
        await history.waitUntilRecentHeld()
        loading.cancel()
        model.hide(at: Date())
        if clear {
            model.clear()
            await history.setPlays(.success([play("b")]))
            await model.reveal(at: Date())
        }
        let reopened = clear ? nil : await startLibraryReveal { await model.reveal(at: Date()) }
        await history.releaseRecent()
        await loading.value
        await reopened?.value
        let expected = [testTrack(clear ? "b" : "a")]
        #expect(model.tracks == expected)
        #expect(!model.isLoading && model.error == nil)
        #expect(await history.recentCalls == (clear ? 2 : 1))
        await model.reveal(at: Date())
        #expect(model.tracks == expected)
        #expect(await history.recentCalls == (clear ? 2 : 1))
    }
}
