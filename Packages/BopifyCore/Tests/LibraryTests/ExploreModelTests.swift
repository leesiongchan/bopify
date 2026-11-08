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

private actor PartialHistory: ListeningHistoryService {
    let results: [TopItemKind: Result<[StationSeed], LibraryError>]
    private(set) var requests: [TopItemKind] = []

    init(_ results: [TopItemKind: Result<[StationSeed], LibraryError>]) { self.results = results }
    func recentlyPlayed() async throws -> [RecentPlay] { [] }
    func topItems(_ kind: TopItemKind) async throws -> [StationSeed] {
        requests.append(kind)
        return try (results[kind] ?? .success([])).get()
    }
}

private actor DiscoveryHistory: ListeningHistoryService {
    let recent: Result<[RecentPlay], LibraryError>
    let top: [String: [StationSeed]]
    private(set) var requests: [String] = []
    init(recent: Result<[RecentPlay], LibraryError>, top: [String: [StationSeed]] = [:]) {
        self.recent = recent
        self.top = top
    }
    func recentlyPlayed() async throws -> [RecentPlay] { requests.append("recent"); return try recent.get() }
    func topItems(_ kind: TopItemKind) async throws -> [StationSeed] { try await topItems(kind, timeRange: .mediumTerm) }
    func topItems(_ kind: TopItemKind, timeRange: TopItemTimeRange) async throws -> [StationSeed] {
        let key = "\(kind.rawValue):\(timeRange.rawValue)"
        requests.append(key)
        return top[key] ?? []
    }
}

@MainActor
private final class StationRetryClock {
    private(set) var delays: [Duration] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func sleep(_ delay: Duration) async throws {
        delays.append(delay)
        // Deliberately ignores cancellation: the model must reject stale callbacks itself.
        await withCheckedContinuation { waiters.append($0) }
    }
    func advance() -> Bool {
        guard !waiters.isEmpty else { return false }
        waiters.removeFirst().resume()
        return true
    }
    func settle() async { for _ in 0..<100 { await Task.yield() } }
}

@Suite("ExploreModel") @MainActor
struct ExploreModelTests {
    @Test func authorizedLibrarySongsRemainPlayableWhenEveryNativeRadioIsUnavailable() async {
        let liked = [testTrack("liked1"), testTrack("liked2"), testTrack("liked3")]
        let explore = ExploreModel(history: FakeHistory(), savedTracks: FakeSavedTracks(liked),
                                   radio: { _ in throw RadioFailure.unavailable }, now: Date.init)
        await explore.reveal(at: Date())
        #expect(Set(explore.tracks.map(\.uri)) == Set(liked.map(\.uri)))
        #expect(explore.stationFailure == nil)
        #expect(explore.isUsingLibrarySuggestions && !explore.hasMore)
        if let selected = explore.tracks.first {
            let request = explore.playRequest(for: selected)
            #expect(request.contextURI == selected.uri)
            #expect(request.followingTrackURIs == explore.tracks.dropFirst().map(\.uri))
        } else { Issue.record("Authorized songs were discarded because the optional radio service failed") }
    }

    @Test func authorizedSuggestionsAppearBeforeASlowNativeRadioFinishes() async {
        let history = FakeHistory(), radio = FakeRadio(), clock = StationRetryClock()
        let recent = testTrack("recent"), liked = testTrack("liked")
        await history.setPlays(.success([RecentPlay(track: recent, contextURI: nil)]))
        radio.holding = [recent.uri, liked.uri]
        let explore = ExploreModel(history: history, savedTracks: FakeSavedTracks([liked]),
                                   radio: { try await radio.request($0) }, now: Date.init)
        let opening = Task { await explore.reveal(at: Date()) }
        await radio.waitUntilHeld(recent.uri)
        await radio.waitUntilHeld(liked.uri)
        await clock.settle()
        #expect(Set(explore.tracks.map(\.uri)) == Set([recent.uri, liked.uri]))
        radio.release(recent.uri)
        radio.release(liked.uri)
        await opening.value
        #expect(explore.stationFailure == nil)
    }

    @Test func anArtistAnchorUsesOnlyMatchingAuthorizedTracksWhenRadioIsUnavailable() async {
        let artist = seed("artist", "match")
        let matching = Track(uri: testTrack("match").uri, title: "Matched song", artists: [ArtistSummary(name: artist.name)],
                             albumTitle: nil, artwork: nil, durationMs: 180_000)
        let other = Track(uri: testTrack("other").uri, title: "Other song", artists: [ArtistSummary(name: "Other Artist")],
                          albumTitle: nil, artwork: nil, durationMs: 180_000)
        let history = FakeHistory()
        await history.setTop(.tracks, [StationSeed(track: matching)])
        await history.setTop(.artists, [artist])
        let explore = ExploreModel(history: history, savedTracks: FakeSavedTracks([other]),
                                   radio: { _ in throw RadioFailure.unavailable }, now: Date.init)
        await explore.reveal(at: Date())
        await explore.selectChip(artist.uri)
        #expect(explore.tracks == [matching])
        #expect(explore.stationFailure == nil)
    }

    @Test func seedNamesWithoutTrackMetadataCannotBecomeFakeLibrarySongs() async {
        let history = FakeHistory()
        await history.setTop(.tracks, [seed("track", "nameOnly")])
        let explore = ExploreModel(history: history, savedTracks: FakeSavedTracks([]),
                                   radio: { _ in throw RadioFailure.unavailable }, now: Date.init)
        await explore.reveal(at: Date())
        #expect(explore.tracks.isEmpty && explore.stationFailure == .unavailable)
        #expect(!explore.isUsingLibrarySuggestions)
    }

    @Test func retainedTopTrackMetadataCanPopulateExploreWithoutRecentOrSavedSongs() async {
        let history = FakeHistory()
        let song = testTrack("top")
        await history.setTop(.tracks, [StationSeed(track: song)])
        let explore = ExploreModel(history: history, savedTracks: FakeSavedTracks([]),
                                   radio: { _ in throw RadioFailure.unavailable }, now: Date.init)
        await explore.reveal(at: Date())
        #expect(explore.tracks == [song] && explore.isUsingLibrarySuggestions)
    }

    @Test func anArtistWithoutMatchingLibraryMetadataDoesNotShowUnrelatedSongs() async {
        let history = FakeHistory()
        let artist = seed("artist", "artist")
        let other = Track(uri: testTrack("other").uri, title: "Other", artists: [ArtistSummary(name: "Someone else")],
                          albumTitle: nil, artwork: nil, durationMs: 180_000)
        await history.setTop(.artists, [artist])
        let explore = ExploreModel(history: history, savedTracks: FakeSavedTracks([other]),
                                   radio: { _ in throw RadioFailure.unavailable }, now: Date.init)
        await explore.reveal(at: Date())
        #expect(explore.selectedSeed == other.uri && explore.tracks == [other])
        await explore.selectChip(artist.uri)
        #expect(explore.tracks.isEmpty && explore.stationFailure == .unavailable)
        #expect(!explore.isUsingLibrarySuggestions)
    }

    @Test func healthyRadioEnrichesTheInitialLibraryWindowWithoutDumpingTheSavedPool() async {
        let history = FakeHistory(), radio = FakeRadio()
        let liked = (1...4).map { testTrack("liked\($0)") }
        radio.results[liked[0].uri] = .success(mix("radio", ["fresh", "liked1"]))
        let explore = model(history, radio, liked: liked)
        await explore.reveal(at: Date())
        #expect(explore.tracks.prefix(3).map(\.uri) == liked.prefix(3).map(\.uri))
        #expect(explore.tracks.map(\.uri).contains(testTrack("fresh").uri))
        #expect(!explore.tracks.map(\.uri).contains(liked[3].uri))
        #expect(explore.tracks.filter { $0.uri == liked[0].uri }.count == 1)
        #expect(!explore.isUsingLibrarySuggestions)
    }

    @Test func radioRecoveryAppendsToThePlayableLibraryMixWithoutResettingSelection() async {
        let history = FakeHistory(), radio = FakeRadio(), clock = StationRetryClock()
        let liked = (1...4).map { testTrack("liked\($0)") }
        radio.results[liked[0].uri] = .failure(.unavailable)
        let explore = ExploreModel(history: history, savedTracks: FakeSavedTracks(liked),
                                   radio: { try await radio.request($0) }, now: Date.init,
                                   retrySleep: { try await clock.sleep($0) })
        await explore.reveal(at: Date())
        await clock.settle()
        let before = explore.tracks.map(\.uri)
        #expect(before == liked.map(\.uri) && explore.isUsingLibrarySuggestions && !explore.hasMore)
        explore.select(liked[1].uri)
        radio.results[liked[0].uri] = .success(mix("recovered", ["fresh", "liked1"]))
        guard clock.advance() else { Issue.record("The optional radio recovery was not scheduled"); return }
        await clock.settle()
        #expect(explore.tracks.prefix(before.count).map(\.uri) == before)
        #expect(explore.tracks.last?.uri == testTrack("fresh").uri && explore.selectedURI == liked[1].uri)
        #expect(!explore.isUsingLibrarySuggestions)
        explore.clear()
    }

    @Test func aMetadataOutageKeepsTheLibraryMixFiniteAndStopsAtTheFirstRadioBatch() async {
        let history = FakeHistory(), radio = FakeRadio(), clock = StationRetryClock()
        let songs = (0..<60).map { testTrack("recent\($0)") }
        await history.setPlays(.success(songs.map { RecentPlay(track: $0, contextURI: nil) }))
        for song in songs { radio.results[song.uri] = .failure(.unavailable) }
        let explore = ExploreModel(history: history, savedTracks: FakeSavedTracks([]),
                                   radio: { try await radio.request($0) }, now: Date.init,
                                   retrySleep: { try await clock.sleep($0) })
        await explore.reveal(at: Date())
        await clock.settle()
        #expect(explore.tracks.count == 50 && Set(explore.tracks.map(\.uri)).count == 50)
        #expect(radio.requests.count == 3 && !explore.hasMore && explore.isUsingLibrarySuggestions)
        explore.clear()
        _ = clock.advance()
        await clock.settle()
        #expect(explore.tracks.isEmpty && !explore.isUsingLibrarySuggestions)
    }

    private func seed(_ kind: String, _ id: String) -> StationSeed {
        StationSeed(uri: SpotifyURI("spotify:\(kind):\(id)")!, name: id)
    }
    private func mix(_ id: String, _ tracks: [String]) -> RadioMix {
        RadioMix(contextURI: SpotifyURI("spotify:playlist:\(id)")!, tracks: tracks.map(testTrack))
    }
    private func model(_ history: FakeHistory, _ radio: FakeRadio, liked: [Track] = [], clock: TestClock = TestClock()) -> ExploreModel {
        ExploreModel(history: history, savedTracks: FakeSavedTracks(liked), radio: { try await radio.request($0) }, now: { clock.date })
    }

    @Test func collectsRecentShortTermFamiliarAndLikedSignals() async {
        let recent = testTrack("recent"), liked = testTrack("liked")
        let short = seed("track", "short"), artist = seed("artist", "artist"), familiar = seed("track", "familiar")
        let history = DiscoveryHistory(recent: .success([RecentPlay(track: recent, contextURI: nil)]),
                                       top: ["tracks:short_term": [short], "artists:short_term": [artist], "tracks:medium_term": [familiar]])
        let saved = FakeSavedTracks([liked])
        let explore = ExploreModel(history: history, savedTracks: saved,
                                   radio: { _ in mix("station", ["candidate"]) }, now: Date.init)
        await explore.reveal(at: Date())
        #expect(explore.chips.map(\.uri) == [recent.uri, short.uri, artist.uri, familiar.uri, liked.uri])
        #expect(await history.requests == ["recent", "tracks:short_term", "artists:short_term", "tracks:medium_term"])
        #expect(await saved.requests == [[0, 5]])
    }

    @Test(arguments: [LibraryError.authorizationRequired, .forbidden, .rateLimited(retryAfterSeconds: 30), .quotaExceeded(retryAfterSeconds: 60)])
    func accountFailureInTheFirstSourceStopsAllFurtherRequests(failure: LibraryError) async {
        let clock = TestClock(), history = DiscoveryHistory(recent: .failure(failure)), saved = FakeSavedTracks([])
        var radioRequests = 0
        let explore = ExploreModel(history: history, savedTracks: saved, radio: { _ in
            radioRequests += 1
            throw RadioFailure.noMix
        }, now: { clock.date })
        await explore.reveal(at: clock.date)
        #expect(explore.error == failure && explore.chips.isEmpty && radioRequests == 0)
        #expect(await history.requests == ["recent"])
        #expect(await saved.requests.isEmpty)
        if failure == .rateLimited(retryAfterSeconds: 30) { #expect(explore.retryAfter == clock.date.addingTimeInterval(30)) }
        if failure == .quotaExceeded(retryAfterSeconds: 60) { #expect(explore.retryAfter == clock.date.addingTimeInterval(60)) }
    }

    @Test func aColdAccountDoesNotInventDiscoveries() async {
        var radioRequests = 0
        let explore = ExploreModel(history: FakeHistory(), savedTracks: FakeSavedTracks([]), radio: { _ in
            radioRequests += 1
            throw RadioFailure.noMix
        }, now: Date.init)
        await explore.reveal(at: Date())
        #expect(explore.chips.isEmpty && explore.tracks.isEmpty && radioRequests == 0)
        #expect(!explore.isLoading && !explore.hasMore && explore.error == nil && explore.stationFailure == nil)
    }

    @Test func initialCandidateConcurrencyIsLimitedToThree() async {
        let history = FakeHistory(), radio = FakeRadio()
        let seeds = (0..<6).map { seed("track", "seed\($0)") }
        await history.setTop(.tracks, seeds)
        radio.holding = Set(seeds.prefix(3).map(\.uri))
        for seed in seeds { radio.results[seed.uri] = .success(mix("station", [seed.name])) }
        let explore = model(history, radio)
        let opening = Task { await explore.reveal(at: Date()) }
        for seed in seeds.prefix(3) { await radio.waitUntilHeld(seed.uri) }
        #expect(Set(radio.requests) == Set(seeds.prefix(3).map(\.uri)))
        for seed in seeds.prefix(3) { radio.release(seed.uri) }
        await opening.value
        #expect(radio.requests.count == 3 && explore.hasMore)
    }

    @Test func missingMixesAdvanceToTheNextCandidateBatchWithoutAnotherClick() async {
        let history = FakeHistory(), radio = FakeRadio()
        let seeds = (0..<4).map { seed("track", "seed\($0)") }
        await history.setTop(.tracks, seeds)
        for seed in seeds { radio.results[seed.uri] = .failure(.noMix) }
        radio.results[seeds[3].uri] = .success(mix("station", ["discovered"]))
        let explore = model(history, radio)
        await explore.reveal(at: Date())
        #expect(radio.requests.count == 4)
        #expect(explore.tracks.map(\.uri) == [testTrack("discovered").uri] && explore.stationFailure == nil)
    }

    @Test func missingMixesExhaustOnlyTheBoundedCandidatePool() async {
        let history = FakeHistory(), radio = FakeRadio()
        await history.setTop(.tracks, (0..<20).map { seed("track", "seed\($0)") })
        let explore = model(history, radio)
        await explore.reveal(at: Date())
        #expect(radio.requests.count == 12 && Set(radio.requests).count == 12)
        #expect(explore.stationFailure == .noMix && explore.tracks.isEmpty && !explore.hasMore)
    }

    @Test func aSharedMetadataOutageDoesNotFanOutToTheRemainingSeeds() async {
        let history = FakeHistory(), radio = FakeRadio(), clock = StationRetryClock()
        let seeds = (0..<6).map { seed("track", "seed\($0)") }
        await history.setTop(.tracks, seeds)
        for seed in seeds { radio.results[seed.uri] = .failure(.unavailable) }
        let explore = ExploreModel(history: history, savedTracks: FakeSavedTracks([]), radio: { try await radio.request($0) },
                                   now: Date.init, retrySleep: { try await clock.sleep($0) })
        await explore.reveal(at: Date())
        await clock.settle()
        #expect(radio.requests.count == 3 && clock.delays == [.seconds(2)])
        explore.clear()
        _ = clock.advance()
        await clock.settle()
    }

    @Test func anEmptyRadioResponseCanRecoverWhenExplicitlyRetried() async {
        let history = FakeHistory(), radio = FakeRadio()
        let a = seed("track", "a")
        await history.setTop(.tracks, [a])
        radio.results[a.uri] = .success(mix("empty", []))
        let explore = model(history, radio)
        await explore.reveal(at: Date())
        #expect(explore.stationFailure == .noMix)
        radio.results[a.uri] = .success(mix("recovered", ["fresh"]))
        await explore.retryStation()
        #expect(radio.requests.count == 2)
        #expect(explore.tracks.map(\.uri) == [testTrack("fresh").uri] && explore.stationFailure == nil)
    }

    @Test(arguments: [false, true])
    func partialContentDoesNotAcceptLateResultsAfterHideOrClear(clear: Bool) async {
        let history = FakeHistory(), radio = FakeRadio(), clock = StationRetryClock()
        let a = seed("track", "slow"), b = seed("track", "healthy")
        await history.setTop(.tracks, [a, b])
        radio.results = [a.uri: .success(mix("slow", ["late"])),
                         b.uri: .success(mix("healthy", ["one", "two", "three", "four"]))]
        radio.holding = [a.uri]
        let explore = model(history, radio)
        let opening = Task { await explore.reveal(at: Date()) }
        await radio.waitUntilHeld(a.uri)
        await clock.settle()
        let partial = explore.tracks.map(\.uri)
        #expect(partial.count == 3)
        if clear { explore.clear() } else { explore.hide(at: Date()) }
        radio.release(a.uri)
        await opening.value
        #expect(explore.tracks.map(\.uri) == (clear ? [] : partial))
        #expect(!explore.isLoading)
    }

    @Test func discoveryCombinesThreeSeedRadiosWithoutDuplicateSongs() async {
        let history = FakeHistory(), radio = FakeRadio()
        let seeds = [seed("track", "a"), seed("track", "b"), seed("track", "c")]
        await history.setTop(.tracks, seeds)
        radio.results = [seeds[0].uri: .success(mix("a", ["x", "shared"])),
                         seeds[1].uri: .success(mix("b", ["shared", "y"])),
                         seeds[2].uri: .success(mix("c", ["z"]))]
        let explore = model(history, radio)
        await explore.reveal(at: Date())
        #expect(Set(radio.requests) == Set(seeds.map(\.uri)))
        #expect(Set(explore.tracks.map(\.uri)) == Set(["x", "shared", "y", "z"].map { testTrack($0).uri }))
        #expect(explore.tracks.count == 4 && explore.stationFailure == nil)
    }

    @Test func discoveryKeepsSuccessfulCandidatesWhenTheAnchorHasNoMix() async {
        let history = FakeHistory(), radio = FakeRadio()
        let seeds = [seed("track", "a"), seed("track", "b"), seed("track", "c")]
        await history.setTop(.tracks, seeds)
        radio.results = [seeds[0].uri: .failure(.noMix),
                         seeds[1].uri: .success(mix("b", ["y"])),
                         seeds[2].uri: .success(mix("c", ["z"]))]
        let explore = model(history, radio)
        await explore.reveal(at: Date())
        #expect(explore.stationFailure == nil)
        #expect(Set(explore.tracks.map(\.uri)) == Set([testTrack("y").uri, testTrack("z").uri]))
    }

    @Test func approachingTheEndAppendsNewCandidatesWithoutMovingSelection() async {
        let history = FakeHistory(), radio = FakeRadio()
        let seeds = (0..<6).map { seed("track", "seed\($0)") }
        await history.setTop(.tracks, seeds)
        for (index, seed) in seeds.enumerated() {
            radio.results[seed.uri] = .success(mix("mix\(index)", ["song\(index)", "shared"]))
        }
        let explore = model(history, radio)
        await explore.reveal(at: Date())
        let initial = explore.tracks.map(\.uri)
        #expect(radio.requests.count == 3 && explore.hasMore)
        guard let selected = initial.first, let end = initial.last else { Issue.record("No initial discoveries"); return }
        explore.select(selected)
        await explore.loadMoreIfNeeded(near: end)
        #expect(radio.requests.count == 6 && !explore.hasMore)
        #expect(explore.tracks.prefix(initial.count).map(\.uri) == initial)
        #expect(explore.selectedURI == selected)
        #expect(Set(explore.tracks.map(\.uri)).count == explore.tracks.count)
    }

    @Test func aNewBrowsingSessionRefreshesExpiredRadioMixes() async {
        let history = FakeHistory(), radio = FakeRadio(), clock = TestClock()
        let a = seed("track", "a")
        await history.setTop(.tracks, [a])
        radio.results[a.uri] = .success(mix("old", ["old"]))
        let explore = model(history, radio, clock: clock)
        await explore.reveal(at: clock.date)
        explore.hide(at: clock.date)
        clock.advance(6 * 60 * 60)
        radio.results[a.uri] = .success(mix("fresh", ["fresh"]))
        await explore.reveal(at: clock.date)
        #expect(radio.requests == [a.uri, a.uri])
        #expect(explore.tracks.map(\.uri) == [testTrack("fresh").uri])
    }

    @Test func playSelectionIncludesOnlyFollowingDiscoverySongs() async {
        let history = FakeHistory(), radio = FakeRadio()
        let a = seed("track", "a")
        await history.setTop(.tracks, [a])
        radio.results[a.uri] = .success(mix("station", (0..<30).map { "song\($0)" }))
        let explore = model(history, radio)
        await explore.reveal(at: Date())
        let chosen = explore.tracks[2]
        let request = explore.playRequest(for: chosen)
        #expect(request.contextURI == chosen.uri)
        #expect(request.followingTrackURIs == Array(explore.tracks.dropFirst(3).prefix(20).map(\.uri)))
    }

    @Test func aSlowSeedDoesNotHideHealthyDiscoveriesOrReorderTheInitialWindow() async {
        let history = FakeHistory(), radio = FakeRadio(), clock = StationRetryClock()
        let a = seed("track", "slow"), b = seed("track", "healthy")
        await history.setTop(.tracks, [a, b])
        radio.results = [a.uri: .success(mix("slow", ["late1", "late2"])),
                         b.uri: .success(mix("healthy", ["first1", "first2", "first3", "more"]))]
        radio.holding = [a.uri]
        let explore = model(history, radio)
        let opening = Task { await explore.reveal(at: Date()) }
        await radio.waitUntilHeld(a.uri)
        await clock.settle()
        let initial = explore.tracks.map(\.uri)
        #expect(initial == ["first1", "first2", "first3"].map { testTrack($0).uri })
        #expect(explore.isLoading)
        if let first = initial.first { explore.select(first) }
        radio.release(a.uri)
        await opening.value
        #expect(explore.tracks.prefix(initial.count).map(\.uri) == initial)
        #expect(explore.selectedURI == initial.first)
        #expect(explore.tracks.count == 6 && !explore.isLoading)
    }

    @Test(arguments: [RadioFailure.network, .unavailable])
    func transientStationFailureRecoversWithoutAnotherClick(failure: RadioFailure) async {
        let history = FakeHistory(), radio = FakeRadio(), clock = StationRetryClock()
        let a = seed("track", "a")
        await history.setTop(.tracks, [a])
        radio.results[a.uri] = .failure(failure)
        let explore = ExploreModel(history: history, savedTracks: FakeSavedTracks([]),
                                   radio: { try await radio.request($0) }, now: Date.init,
                                   retrySleep: { try await clock.sleep($0) })
        await explore.reveal(at: Date())
        await clock.settle()
        #expect(clock.delays == [.seconds(2)])
        radio.results[a.uri] = .success(mix("station", ["recovered"]))
        guard clock.advance() else { Issue.record("No automatic retry scheduled"); return }
        await clock.settle()
        #expect(radio.requests == [a.uri, a.uri])
        #expect(explore.stationFailure == nil && explore.tracks.map(\.uri) == [testTrack("recovered").uri])
    }

    @Test func automaticStationRetriesAreBoundedAndManualRetryRestartsTheBudget() async {
        let history = FakeHistory(), radio = FakeRadio(), clock = StationRetryClock()
        let a = seed("track", "a")
        await history.setTop(.tracks, [a])
        radio.results[a.uri] = .failure(.network)
        let explore = ExploreModel(history: history, savedTracks: FakeSavedTracks([]),
                                   radio: { try await radio.request($0) }, now: Date.init,
                                   retrySleep: { try await clock.sleep($0) })
        await explore.reveal(at: Date())
        await clock.settle()
        for _ in 0..<3 {
            guard clock.advance() else { Issue.record("Missing bounded retry"); return }
            await clock.settle()
        }
        #expect(clock.delays == [.seconds(2), .seconds(5), .seconds(15)])
        #expect(radio.requests.count == 4)
        #expect(!clock.advance())
        await explore.retryStation()
        await clock.settle()
        #expect(radio.requests.count == 5)
        #expect(clock.delays.last == .seconds(2))
        explore.clear()
        _ = clock.advance()
        await clock.settle()
    }

    @Test(arguments: [RadioFailure.noMix, .noTopTrack])
    func terminalStationFailuresDoNotRetry(failure: RadioFailure) async {
        let history = FakeHistory(), radio = FakeRadio(), clock = StationRetryClock()
        let a = seed("track", "a")
        await history.setTop(.tracks, [a])
        radio.results[a.uri] = .failure(failure)
        let explore = ExploreModel(history: history, savedTracks: FakeSavedTracks([]),
                                   radio: { try await radio.request($0) }, now: Date.init,
                                   retrySleep: { try await clock.sleep($0) })
        await explore.reveal(at: Date())
        await clock.settle()
        #expect(clock.delays.isEmpty && radio.requests == [a.uri])
    }

    @Test(arguments: ["hide", "switch", "clear"])
    func staleStationRetryCannotRunAfterLeavingItsContext(action: String) async {
        let history = FakeHistory(), radio = FakeRadio(), clock = StationRetryClock()
        let a = seed("track", "a"), b = seed("track", "b")
        await history.setTop(.tracks, [a, b, seed("track", "c"), seed("track", "d")])
        radio.results[a.uri] = .failure(.network)
        radio.results[b.uri] = .success(mix("station", ["other"]))
        let explore = ExploreModel(history: history, savedTracks: FakeSavedTracks([]),
                                   radio: { try await radio.request($0) }, now: Date.init,
                                   retrySleep: { try await clock.sleep($0) })
        await explore.reveal(at: Date())
        await clock.settle()
        #expect(clock.delays == [.seconds(2)])
        switch action {
        case "hide": explore.hide(at: Date())
        case "switch": await explore.selectChip(b.uri)
        default: explore.clear()
        }
        _ = clock.advance()
        await clock.settle()
        #expect(radio.requests.filter { $0 == a.uri }.count == 1)
        if action == "clear" { #expect(explore.chips.isEmpty && explore.tracks.isEmpty) }
    }

    @Test func anUnmatchedRevealKeepsAutomaticRetryAlive() async {
        let history = FakeHistory(), radio = FakeRadio(), clock = StationRetryClock()
        let a = seed("track", "a")
        await history.setTop(.tracks, [a])
        radio.results[a.uri] = .failure(.network)
        let explore = ExploreModel(history: history, savedTracks: FakeSavedTracks([]),
                                   radio: { try await radio.request($0) }, now: Date.init,
                                   retrySleep: { try await clock.sleep($0) })
        await explore.reveal(at: Date())
        await explore.reveal(at: Date())
        explore.hide(at: Date())
        await clock.settle()
        radio.results[a.uri] = .success(mix("station", ["recovered"]))
        guard clock.advance() else { Issue.record("Retry was lost during a view handoff"); return }
        await clock.settle()
        #expect(radio.requests.count == 2 && explore.stationFailure == nil)
    }

    @Test func reopeningResumesTheRemainingRetryBudget() async {
        let history = FakeHistory(), radio = FakeRadio(), clock = StationRetryClock()
        let a = seed("track", "a")
        await history.setTop(.tracks, [a])
        radio.results[a.uri] = .failure(.network)
        let explore = ExploreModel(history: history, savedTracks: FakeSavedTracks([]),
                                   radio: { try await radio.request($0) }, now: Date.init,
                                   retrySleep: { try await clock.sleep($0) })
        await explore.reveal(at: Date())
        await clock.settle()
        guard clock.advance() else { Issue.record("No first retry"); return }
        await clock.settle()
        explore.hide(at: Date())
        _ = clock.advance()
        await clock.settle()
        #expect(radio.requests.count == 2)
        await explore.reveal(at: Date())
        await clock.settle()
        #expect(clock.delays == [.seconds(2), .seconds(5), .seconds(5)])
        radio.results[a.uri] = .success(mix("station", ["recovered"]))
        guard clock.advance() else { Issue.record("No retry after reopening"); return }
        await clock.settle()
        #expect(radio.requests.count == 3 && explore.stationFailure == nil)
    }

    @Test func aStationProviderIgnoringCancellationCannotRepopulateClearedLibrary() async {
        let history = FakeHistory(), radio = FakeRadio()
        let a = seed("track", "a")
        await history.setTop(.tracks, [a])
        radio.holding = [a.uri]
        radio.results[a.uri] = .success(mix("station", ["stale"]))
        let explore = model(history, radio)
        let revealing = Task { await explore.reveal(at: Date()) }
        await radio.waitUntilHeld(a.uri)
        explore.clear()
        radio.release(a.uri)
        await revealing.value
        #expect(explore.chips.isEmpty && explore.tracks.isEmpty && explore.selectedSeed == nil)
        #expect(!explore.isLoading && explore.stationFailures.isEmpty)
    }

    @Test func anIdentityChangeRestartsTheInitialStationAfterTheOldViewHides() async {
        let history = FakeHistory(), clock = StationRetryClock()
        let a = seed("track", "a")
        await history.setTop(.tracks, [a])
        let station = mix("station", ["recovered"])
        var requests = 0
        var cancelled: CheckedContinuation<Void, Never>?
        let explore = ExploreModel(history: history, savedTracks: FakeSavedTracks([]), radio: { _ in
            requests += 1
            if requests == 1 {
                do { try await Task.sleep(for: .seconds(100)) }
                catch {
                    // Keep the original chip request alive until the replacement view has joined it.
                    await withCheckedContinuation { cancelled = $0 }
                    throw error
                }
            }
            return station
        }, now: Date.init)
        let opening = Task { await explore.reveal(at: Date()) }
        while requests == 0 { await Task.yield() }
        explore.hide(at: Date())
        while cancelled == nil { await Task.yield() }
        let replacement = await startLibraryReveal { await explore.reveal(at: Date()) }
        await clock.settle()
        cancelled?.resume()
        await opening.value
        await replacement.value
        #expect(requests == 2)
        #expect(explore.tracks.map(\.uri) == [testTrack("recovered").uri])
        #expect(!explore.isLoading && explore.stationFailure == nil)
    }

    @Test(arguments: [TopItemKind.tracks, .artists])
    func oneUnavailableTopSourceDoesNotDiscardTheOther(kind: TopItemKind) async {
        let other: TopItemKind = kind == .tracks ? .artists : .tracks
        let available = seed(other == .tracks ? "track" : "artist", "available")
        let history = PartialHistory([kind: .failure(.unavailable), other: .success([available])])
        let radio = FakeRadio()
        radio.results[available.uri] = .success(mix("station", ["song"]))
        let explore = ExploreModel(history: history, savedTracks: FakeSavedTracks([]),
                                   radio: { try await radio.request($0) }, now: Date.init)
        await explore.reveal(at: Date())
        #expect(explore.error == nil)
        #expect(explore.chips == [available])
        #expect(explore.tracks.map(\.uri) == [testTrack("song").uri])
    }

    @Test func unavailableTopSourcesCanStillUseLikedSongs() async {
        let history = PartialHistory([.tracks: .failure(.unavailable), .artists: .failure(.invalidResponse)])
        let liked = testTrack("liked")
        let explore = ExploreModel(history: history, savedTracks: FakeSavedTracks([liked]),
                                   radio: { _ in throw RadioFailure.noMix }, now: Date.init)
        await explore.reveal(at: Date())
        #expect(explore.error == nil && explore.chips.map(\.uri) == [liked.uri])
    }

    @Test(arguments: [LibraryError.authorizationRequired, .forbidden, .rateLimited(retryAfterSeconds: 30), .quotaExceeded(retryAfterSeconds: 60)])
    func accountAndRateLimitFailuresDoNotFanOutToMoreRequests(failure: LibraryError) async {
        let history = PartialHistory([.tracks: .failure(failure)])
        let saved = FakeSavedTracks([testTrack("liked")])
        let explore = ExploreModel(history: history, savedTracks: saved,
                                   radio: { _ in throw RadioFailure.noMix }, now: Date.init)
        await explore.reveal(at: Date())
        #expect(explore.error == failure && explore.chips.isEmpty)
        #expect(await history.requests == [.tracks])
        #expect(await saved.requests.isEmpty)
    }

    @Test func failedTopSourcesAndEmptyLikedSongsRemainAnError() async {
        let history = PartialHistory([.tracks: .failure(.unavailable), .artists: .success([])])
        let explore = ExploreModel(history: history, savedTracks: FakeSavedTracks([]),
                                   radio: { _ in throw RadioFailure.noMix }, now: Date.init)
        await explore.reveal(at: Date())
        #expect(explore.error == .unavailable && explore.chips.isEmpty)
    }

    @Test func interleavesDistinctTopTracksAndArtistsAndCapsAtTwelve() async {
        let history = FakeHistory()
        await history.setTop(.tracks, (1...6).map { seed("track", "t\($0)") })
        await history.setTop(.artists, (1...6).map { seed("artist", "a\($0)") })
        let explore = model(history, FakeRadio())
        await explore.reveal(at: Date())
        #expect(explore.chips.map(\.name) == ["t1", "a1", "t2", "a2", "t3", "a3", "t4", "a4", "t5", "a5", "t6", "a6"])
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
        #expect(await history.topCalls == 6)
        #expect(explore.chips.map(\.name) == ["t1"])
    }

    @Test func keepsTheActiveSessionStableAndRefreshesAfterOneHourWhenReopened() async {
        let history = FakeHistory()
        let clock = TestClock()
        await history.setTop(.tracks, [seed("track", "t1")])
        let explore = model(history, FakeRadio(), clock: clock)
        await explore.reveal(at: clock.date)
        #expect(await history.topCalls == 3)
        explore.hide(at: clock.date)
        await explore.reveal(at: clock.date.addingTimeInterval(60 * 60 - 1))
        #expect(await history.topCalls == 3)
        await explore.reveal(at: clock.date.addingTimeInterval(2 * 60 * 60))
        #expect(await history.topCalls == 3)
        explore.hide(at: clock.date)
        explore.hide(at: clock.date)
        clock.advance(2 * 60 * 60)
        await explore.reveal(at: clock.date)
        #expect(await history.topCalls == 6)
    }

    @Test func requestsEachStationOnceAndPlaysTheExactSelectedTrack() async {
        let history = FakeHistory()
        let a = seed("track", "a"), b = seed("artist", "b")
        await history.setTop(.tracks, [a])
        await history.setTop(.artists, [b])
        let radio = FakeRadio()
        radio.results = [a.uri: .success(mix("ma", ["x", "y"])), b.uri: .success(mix("mb", ["z"]))]
        let explore = model(history, radio)
        await explore.reveal(at: Date())
        #expect(Set(explore.tracks.map(\.uri)) == Set(["x", "y", "z"].map { testTrack($0).uri }))
        explore.select(testTrack("y").uri)
        await explore.selectChip(b.uri)
        #expect(Set(explore.tracks.map(\.uri)) == Set(["x", "y", "z"].map { testTrack($0).uri }))
        await explore.selectChip(a.uri)
        #expect(explore.selectedURI == testTrack("y").uri)
        #expect(Set(radio.requests) == Set([a.uri, b.uri]) && radio.requests.count == 2)
        let request = explore.playRequest(for: testTrack("y"))
        #expect(request.contextURI == testTrack("y").uri)
        let selectedIndex = explore.tracks.firstIndex { $0.uri == testTrack("y").uri }!
        #expect(request.followingTrackURIs == explore.tracks.dropFirst(selectedIndex + 1).map(\.uri))
    }

    @Test func dropsAStationThatArrivesAfterAnotherChipWasChosen() async {
        let history = FakeHistory()
        let a = seed("track", "a"), b = seed("track", "b")
        await history.setTop(.tracks, [a, b, seed("track", "c"), seed("track", "d")])
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
        #expect(radio.requests.filter { $0 == a.uri }.count == 2)
    }

    @Test func aFailingCandidateLeavesOtherDiscoveriesVisibleWhenRetried() async {
        let history = FakeHistory()
        let a = seed("track", "a"), b = seed("track", "b")
        await history.setTop(.tracks, [a, b])
        let radio = FakeRadio()
        radio.results = [a.uri: .failure(.unavailable), b.uri: .success(mix("mb", ["z"]))]
        let explore = model(history, radio)
        await explore.reveal(at: Date())
        #expect(explore.stationFailure == nil && explore.tracks.map(\.uri) == [testTrack("z").uri])
        await explore.selectChip(b.uri)
        #expect(explore.stationFailure == nil && explore.tracks.count == 1)
        await explore.selectChip(a.uri)
        #expect(explore.stationFailure == nil && explore.tracks.map(\.uri) == [testTrack("z").uri])
        radio.results[a.uri] = .success(mix("ma", ["x"]))
        await explore.retryStation()
        #expect(explore.stationFailure == nil && explore.tracks.map(\.uri) == [testTrack("z").uri, testTrack("x").uri])
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
        #expect(await history.topCalls == (clear ? 4 : 3))
    }
}
