import Foundation
import Testing
import BopifyDomain
@testable import BopifyLibrary

@MainActor
private final class FakeRadio {
    var results: [SpotifyURI: Result<RadioMix, RadioFailure>] = [:]
    var holding: Set<SpotifyURI> = []
    private(set) var requests: [SpotifyURI] = []
    private var held: [SpotifyURI: CheckedContinuation<Void, Never>] = [:]

    func request(_ seed: SpotifyURI) async throws -> RadioMix {
        requests.append(seed)
        if holding.contains(seed) { await withCheckedContinuation { held[seed] = $0 } }
        return try (results[seed] ?? .failure(.noMix)).get()
    }
    func release(_ seed: SpotifyURI) { held.removeValue(forKey: seed)?.resume() }
    func waitUntilHeld(_ seed: SpotifyURI) async { while held[seed] == nil { await Task.yield() } }
}

private actor HeldHistory: ListeningHistoryService {
    private var seeds: [StationSeed]
    private(set) var topCalls = 0
    private var holdsNext = true
    private var held: CheckedContinuation<Void, Never>?
    init(_ seeds: [StationSeed]) { self.seeds = seeds }

    func recentlyPlayed() async throws -> [RecentPlay] { [] }
    func topItems(_ kind: TopItemKind) async throws -> [StationSeed] {
        topCalls += 1
        let result = kind == .tracks ? seeds : []
        if holdsNext {
            holdsNext = false
            await withCheckedContinuation { held = $0 }
        }
        return result
    }
    func setSeeds(_ seeds: [StationSeed]) { self.seeds = seeds }
    func release() { held?.resume(); held = nil }
    func waitUntilHeld() async { while held == nil { await Task.yield() } }
}

private actor FailingSavedTracks: SavedTracksService {
    private var failure: LibraryError?
    private let tracks: [Track]
    init(_ failure: LibraryError, tracks: [Track] = []) { self.failure = failure; self.tracks = tracks }

    func succeed() { failure = nil }
    func savedTracks(offset: Int, limit: Int) async throws -> SavedTracksPage {
        if let failure { throw failure }
        return SavedTracksPage(tracks: Array(tracks.prefix(limit)), nextOffset: nil)
    }
}

@Suite("ExploreModel") @MainActor
struct ExploreModelTests {
    private func seed(_ kind: String, _ id: String) -> StationSeed {
        StationSeed(uri: SpotifyURI("spotify:\(kind):\(id)")!, name: id)
    }
    private func mix(_ id: String, _ tracks: [String]) -> RadioMix {
        RadioMix(contextURI: SpotifyURI("spotify:playlist:\(id)")!, tracks: tracks.map(testTrack))
    }
    private func model(_ history: FakeHistory, _ radio: FakeRadio, liked: [Track] = [], clock: TestClock = TestClock()) -> ExploreModel {
        ExploreModel(history: history, savedTracks: FakeSavedTracks(liked), radio: { try await radio.request($0) }, now: { clock.date })
    }

    @Test func interleavesTopTracksAndArtistsAndCapsAtTen() async {
        let history = FakeHistory()
        await history.setTop(.tracks, (1...6).map { seed("track", "t\($0)") })
        await history.setTop(.artists, (1...6).map { seed("artist", "a\($0)") })
        let explore = model(history, FakeRadio())
        await explore.reveal(at: Date())
        #expect(explore.chips.map(\.name) == ["t1", "a1", "t2", "a2", "t3", "a3", "t4", "a4", "t5", "a5"])
        #expect(explore.selectedSeed == seed("track", "t1").uri)
    }

    @Test func fallsBackToTheFiveNewestLikedSongs() async {
        let liked = (1...8).map { testTrack("l\($0)") }
        let saved = FakeSavedTracks(liked)
        let explore = ExploreModel(history: FakeHistory(), savedTracks: saved, radio: { _ in throw RadioFailure.noMix }, now: Date.init)
        await explore.reveal(at: Date())
        #expect(explore.chips.map(\.uri) == liked.prefix(5).map(\.uri))
        #expect(await saved.requests == [[0, 5]])
    }

    @Test(arguments: [LibraryError.authorizationRequired, .forbidden])
    func likedFallbackAuthorizationFailuresRemainVisible(failure: LibraryError) async {
        let explore = ExploreModel(history: FakeHistory(), savedTracks: FailingSavedTracks(failure),
                                   radio: { _ in throw RadioFailure.noMix }, now: Date.init)
        await explore.reveal(at: Date())
        #expect(explore.chips.isEmpty && explore.error == failure)
    }

    @Test func aRateLimitedLikedFallbackReportsItsErrorUntilRetried() async {
        let clock = TestClock()
        let liked = FailingSavedTracks(.rateLimited(retryAfterSeconds: 30), tracks: [testTrack("l1")])
        let explore = ExploreModel(history: FakeHistory(), savedTracks: liked,
                                   radio: { _ in throw RadioFailure.noMix }, now: { clock.date })
        await explore.reveal(at: clock.date)
        #expect(explore.error == .rateLimited(retryAfterSeconds: 30))
        #expect(explore.retryAfter == clock.date.addingTimeInterval(30))
        await liked.succeed()
        await explore.retry(at: clock.date.addingTimeInterval(30))
        #expect(explore.error == nil && explore.chips.map(\.uri) == [testTrack("l1").uri])
    }

    /// A quick tab round trip can hide the old view after the new one revealed; the model must stay shown.
    @Test func staysShownWhileAnyRevealIsUnmatched() async {
        let liked = FailingSavedTracks(.unavailable, tracks: [testTrack("l1")])
        let explore = ExploreModel(history: FakeHistory(), savedTracks: liked,
                                   radio: { _ in throw RadioFailure.noMix }, now: Date.init)
        await explore.reveal(at: Date())
        await explore.reveal(at: Date())
        explore.hide(at: Date())
        await liked.succeed()
        await explore.retry(at: Date())
        #expect(explore.error == nil && explore.chips.map(\.uri) == [testTrack("l1").uri])
    }

    @Test func clearedLibraryReloadsOnReveal() async {
        let history = FakeHistory()
        await history.setTop(.tracks, [seed("track", "t1")])
        let explore = model(history, FakeRadio())
        await explore.reveal(at: Date())
        explore.clear()
        await explore.reveal(at: Date())
        #expect(await history.topCalls == 4)
        #expect(explore.chips.map(\.name) == ["t1"])
    }

    @Test func keepsChipsForSixHours() async {
        let history = FakeHistory()
        let clock = TestClock()
        await history.setTop(.tracks, [seed("track", "t1")])
        let explore = model(history, FakeRadio(), clock: clock)
        await explore.reveal(at: clock.date)
        #expect(await history.topCalls == 2)
        explore.hide(at: clock.date)
        await explore.reveal(at: clock.date.addingTimeInterval(6 * 60 * 60 - 1))
        #expect(await history.topCalls == 2)
        await explore.reveal(at: clock.date.addingTimeInterval(6 * 60 * 60))
        #expect(await history.topCalls == 4)
    }

    @Test func requestsEachStationOnceAndPlaysFromTheMix() async {
        let history = FakeHistory()
        let a = seed("track", "a"), b = seed("artist", "b")
        await history.setTop(.tracks, [a])
        await history.setTop(.artists, [b])
        let radio = FakeRadio()
        radio.results = [a.uri: .success(mix("ma", ["x", "y"])), b.uri: .success(mix("mb", ["z"]))]
        let explore = model(history, radio)
        await explore.reveal(at: Date())
        #expect(explore.tracks.map(\.uri) == [testTrack("x").uri, testTrack("y").uri])
        explore.select(testTrack("y").uri)
        await explore.selectChip(b.uri)
        #expect(explore.tracks.map(\.uri) == [testTrack("z").uri])
        await explore.selectChip(a.uri)
        #expect(explore.selectedURI == testTrack("y").uri)
        #expect(radio.requests == [a.uri, b.uri])
        #expect(explore.playRequest(for: testTrack("y")) ==
                PlayRequest(contextURI: SpotifyURI("spotify:playlist:ma")!, startTrackURI: testTrack("y").uri))
    }

    @Test func dropsAStationThatArrivesAfterAnotherChipWasChosen() async {
        let history = FakeHistory()
        let a = seed("track", "a"), b = seed("track", "b")
        await history.setTop(.tracks, [a, b])
        let radio = FakeRadio()
        radio.results = [a.uri: .success(mix("ma", ["x"])), b.uri: .success(mix("mb", ["z"]))]
        radio.holding = [a.uri]
        let explore = model(history, radio)
        let opening = Task { await explore.reveal(at: Date()) }
        await radio.waitUntilHeld(a.uri)
        await explore.selectChip(b.uri)
        radio.release(a.uri)
        await opening.value
        #expect(explore.selectedSeed == b.uri)
        #expect(explore.tracks.map(\.uri) == [testTrack("z").uri])
        radio.holding = []
        await explore.selectChip(a.uri)
        #expect(radio.requests == [a.uri, b.uri, a.uri])
    }

    @Test func aFailingStationLeavesOtherChipsWorkingUntilRetried() async {
        let history = FakeHistory()
        let a = seed("track", "a"), b = seed("track", "b")
        await history.setTop(.tracks, [a, b])
        let radio = FakeRadio()
        radio.results = [a.uri: .failure(.unavailable), b.uri: .success(mix("mb", ["z"]))]
        let explore = model(history, radio)
        await explore.reveal(at: Date())
        #expect(explore.stationFailure == .unavailable && explore.tracks.isEmpty)
        await explore.selectChip(b.uri)
        #expect(explore.stationFailure == nil && explore.tracks.count == 1)
        await explore.selectChip(a.uri)
        #expect(explore.stationFailure == .unavailable)
        #expect(radio.requests == [a.uri, b.uri])
        radio.results[a.uri] = .success(mix("ma", ["x"]))
        await explore.retryStation()
        #expect(explore.stationFailure == nil && explore.tracks.map(\.uri) == [testTrack("x").uri])
    }

    @Test(arguments: [false, true])
    func inFlightChipsSurviveViewCancellationButNotLibraryClear(clear: Bool) async {
        let t1 = seed("track", "t1")
        let history = HeldHistory([t1])
        let explore = ExploreModel(history: history, savedTracks: FakeSavedTracks([]), radio: { _ in throw RadioFailure.noMix }, now: Date.init)
        let opening = Task { await explore.reveal(at: Date()) }
        await history.waitUntilHeld()
        opening.cancel()
        explore.hide(at: Date())
        let expected = clear ? seed("track", "new").uri : t1.uri
        if clear {
            explore.clear()
            await history.setSeeds([StationSeed(uri: expected, name: "New")])
            await explore.reveal(at: Date())
        }
        let reopened = clear ? nil : await startLibraryReveal { await explore.reveal(at: Date()) }
        await history.release()
        await opening.value
        await reopened?.value
        #expect(explore.chips.map(\.uri) == [expected])
        #expect(!explore.isLoading)
        await explore.reveal(at: Date())
        #expect(explore.chips.map(\.uri) == [expected])
        #expect(await history.topCalls == (clear ? 3 : 2))
    }
}
