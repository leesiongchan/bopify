import Foundation
import Observation
import os
import BopifyDomain

/// Stable discovery feeds assembled from several real Spotify radio candidates.
@MainActor @Observable
public final class ExploreModel: CoverFlowSource {
    public private(set) var chips: [StationSeed] = []
    public private(set) var selectedSeed: SpotifyURI?
    public private(set) var stationFailures: [SpotifyURI: RadioFailure] = [:]
    public private(set) var error: LibraryError?
    public private(set) var retryAfter: Date?
    private var isLoadingChips = false
    private var loadingSeed: SpotifyURI?
    private struct Feed {
        var tracks: [Track] = []
        var selectedURI: SpotifyURI?
        let candidateSeeds: [SpotifyURI]
        var attempted: Set<SpotifyURI> = []
        var failures: [SpotifyURI: RadioFailure] = [:]
        var hasLoaded = false
        var retries = 0
        var librarySuggestions: [Track] = []
        var hasRadioCandidates = false
    }
    private struct Candidate: Sendable {
        let seed: SpotifyURI
        let result: Result<RadioMix, RadioFailure>
    }
    private var mixes: [SpotifyURI: RadioMix] = [:]
    private var feeds: [SpotifyURI: Feed] = [:]
    private var recentlyPlayed: Set<SpotifyURI> = []
    private var librarySources: [[Track]] = []
    @ObservationIgnored private let history: any ListeningHistoryService
    @ObservationIgnored private let savedTracks: any SavedTracksService
    @ObservationIgnored private let radio: @MainActor (SpotifyURI) async throws -> RadioMix
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let retrySleep: @MainActor (Duration) async throws -> Void
    @ObservationIgnored private var chipsLoadedAt: Date?
    // Counted, not a flag: on a quick tab round trip the old view's hide can land after the new view's reveal.
    @ObservationIgnored private var reveals = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var station: Task<Void, Never>?
    @ObservationIgnored private var chipsRequest: Task<Void, Never>?
    @ObservationIgnored private var automaticRetry: Task<Void, Never>?
    @ObservationIgnored private var retryID: UUID?

    public var isLoading: Bool { isLoadingChips || loadingSeed != nil }
    public var hasMore: Bool {
        guard let seed = selectedSeed, let feed = feeds[seed] else { return false }
        if !feed.hasRadioCandidates, !feed.tracks.isEmpty { return false }
        return feed.candidateSeeds.contains { !feed.attempted.contains($0) }
    }
    private var visible: Bool { reveals > 0 }
    public var tracks: [Track] { selectedSeed.flatMap { feeds[$0]?.tracks } ?? [] }
    public var selectedURI: SpotifyURI? { selectedSeed.flatMap { feeds[$0]?.selectedURI } }
    public var stationFailure: RadioFailure? { selectedSeed.flatMap { stationFailures[$0] } }
    public var isUsingLibrarySuggestions: Bool {
        guard let seed = selectedSeed, let feed = feeds[seed] else { return false }
        return !feed.hasRadioCandidates && !feed.tracks.isEmpty
    }

    public convenience init(history: any ListeningHistoryService, savedTracks: any SavedTracksService,
                            radio: @escaping @MainActor (SpotifyURI) async throws -> RadioMix) {
        self.init(history: history, savedTracks: savedTracks, radio: radio, now: Date.init)
    }
    init(history: any ListeningHistoryService, savedTracks: any SavedTracksService,
         radio: @escaping @MainActor (SpotifyURI) async throws -> RadioMix, now: @escaping () -> Date,
         retrySleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.history = history
        self.savedTracks = savedTracks
        self.radio = radio
        self.now = now
        self.retrySleep = retrySleep
    }

    public func reveal(at date: Date) async {
        let wasVisible = visible
        reveals += 1
        if let chipsRequest {
            await chipsRequest.value
            // A replacement shelf can join while the old shelf cancels its initial station request.
            await openSelectedStation()
            return
        }
        guard !isLoadingChips, retryAfter.map({ $0 <= date }) ?? true else { return }
        if error == nil, let chipsLoadedAt, wasVisible || date.timeIntervalSince(chipsLoadedAt) < 60 * 60 {
            BopifyLog.library.debug("explore chips cache hit")
            await openSelectedStation()
            return
        }
        await loadChips()
    }

    public func hide(at date: Date) {
        reveals = max(0, reveals - 1)
        if !visible {
            cancelAutomaticRetry()
            cancelStationRequest()
        }
    }

    public func select(_ uri: SpotifyURI) {
        guard let seed = selectedSeed, tracks.contains(where: { $0.uri == uri }) else { return }
        feeds[seed]?.selectedURI = uri
    }

    public func selectChip(_ seed: SpotifyURI) async {
        guard seed != selectedSeed, chips.contains(where: { $0.uri == seed }) else { return }
        cancelAutomaticRetry()
        cancelStationRequest()
        selectedSeed = seed
        BopifyLog.library.debug("explore chip selected")
        await openSelectedStation()
    }

    public func retryStation() async {
        guard visible, let seed = selectedSeed, let feed = feeds[seed], !feed.failures.isEmpty else { return }
        cancelAutomaticRetry()
        feeds[seed]?.retries = 0
        let retrying = feed.candidateSeeds.filter { feed.failures[$0] != nil }
        await requestCandidates(Array(retrying.prefix(3)), for: seed)
    }

    public func loadMore() async {
        guard visible, !isLoading, hasMore else { return }
        await openSelectedStation(appending: true)
    }
    public func loadMoreIfNeeded(near uri: SpotifyURI) async {
        guard let index = tracks.firstIndex(where: { $0.uri == uri }), index >= tracks.count - 5 else { return }
        await loadMore()
    }

    public func retry(at date: Date) async {
        guard visible, !isLoadingChips, error != nil, retryAfter.map({ $0 <= date }) ?? true else { return }
        await loadChips()
    }

    public func clear() {
        generation += 1
        chipsRequest?.cancel()
        chipsRequest = nil
        cancelAutomaticRetry()
        cancelStationRequest()
        chips = []
        selectedSeed = nil
        stationFailures = [:]
        isLoadingChips = false
        loadingSeed = nil
        mixes = [:]
        feeds = [:]
        recentlyPlayed = []
        librarySources = []
        error = nil
        retryAfter = nil
        chipsLoadedAt = nil
        BopifyLog.library.debug("explore cleared")
    }

    public func playRequest(for track: Track) -> PlayRequest {
        let following = tracks.firstIndex(where: { $0.uri == track.uri }).map { index in
            Array(tracks.dropFirst(index + 1).prefix(20).map(\.uri))
        } ?? []
        return PlayRequest(contextURI: track.uri, followingTrackURIs: following)
    }

    private func loadChips() async {
        cancelAutomaticRetry()
        cancelStationRequest()
        generation += 1
        let current = generation
        isLoadingChips = true
        error = nil
        retryAfter = nil
        // Top items are shared cache data; a disappearing view must not cancel the next view's load.
        let task = Task { await receiveChips(generation: current) }
        chipsRequest = task
        await task.value
    }

    private func receiveChips(generation current: Int) async {
        defer { if generation == current { isLoadingChips = false; chipsRequest = nil } }
        guard generation == current, !Task.isCancelled else { return }
        BopifyLog.library.debug("explore chips cache miss, loading")
        do {
            let recent = try await source("recent") { try await history.recentlyPlayed() }
            try Task.checkCancellation()
            let tracks = try await source("short tracks") { try await history.topItems(.tracks, timeRange: .shortTerm) }
            try Task.checkCancellation()
            let artists = try await source("short artists") { try await history.topItems(.artists, timeRange: .shortTerm) }
            try Task.checkCancellation()
            let familiar = try await source("familiar tracks") { try await history.topItems(.tracks, timeRange: .mediumTerm) }
            try Task.checkCancellation()
            let liked = try await source("liked") { try await savedTracks.savedTracks(offset: 0, limit: 5).tracks }
            let seeds = ExploreDiscovery.seeds(recent: recent.value ?? [], shortTermTracks: tracks.value ?? [],
                                               shortTermArtists: artists.value ?? [], familiarTracks: familiar.value ?? [],
                                               liked: liked.value ?? [])
            if seeds.isEmpty, let failure = [recent.failure, tracks.failure, artists.failure, familiar.failure, liked.failure].compactMap({ $0 }).first { throw failure }
            guard generation == current, !Task.isCancelled else { return }
            mixes = [:]
            feeds = [:]
            stationFailures = [:]
            recentlyPlayed = Set((recent.value ?? []).map { $0.track.uri })
            librarySources = [(tracks.value ?? []).compactMap(\.track), (familiar.value ?? []).compactMap(\.track),
                              liked.value ?? [], (recent.value ?? []).map(\.track)]
            chips = seeds
            chipsLoadedAt = now()
            if !seeds.contains(where: { $0.uri == selectedSeed }) {
                selectedSeed = seeds.first(where: { !$0.isArtist })?.uri ?? seeds.first?.uri
            }
        } catch {
            guard generation == current, !Task.isCancelled else { return }
            let failure = error as? LibraryError ?? .unavailable
            self.error = failure
            switch failure {
            case let .rateLimited(seconds), let .quotaExceeded(seconds):
                retryAfter = now().addingTimeInterval(TimeInterval(seconds ?? 60))
            default: break
            }
            BopifyLog.library.notice("explore top items request failed")
            return
        }
        isLoadingChips = false
        await openSelectedStation()
    }

    /// An unavailable source must not discard the other source's usable station seeds.
    private func source<Value>(_ name: String, request: () async throws -> Value) async throws -> (value: Value?, failure: LibraryError?) {
        do { return (try await request(), nil) }
        catch {
            if error is CancellationError { throw error }
            let failure = error as? LibraryError ?? .unavailable
            switch failure {
            case .unavailable, .invalidResponse, .notFound:
                BopifyLog.library.notice("explore source unavailable source=\(name, privacy: .public)")
                return (nil, failure)
            default:
                // Account errors and throttling apply to all sources; do not fan out requests.
                throw failure
            }
        }
    }

    /// One station request at a time: choosing another chip cancels the one in flight and drops its result.
    private func openSelectedStation(appending: Bool = false) async {
        guard visible, let seed = selectedSeed else { return }
        if feeds[seed] == nil {
            guard let index = chips.firstIndex(where: { $0.uri == seed }) else { return }
            let ordered = Array(chips[index...]) + Array(chips[..<index])
            var feed = Feed(candidateSeeds: ordered.map(\.uri))
            feed.librarySuggestions = ExploreDiscovery.librarySuggestions(for: chips[index], sources: librarySources, recentlyPlayed: recentlyPlayed)
            feed.tracks = Array(feed.librarySuggestions.prefix(3))
            feed.selectedURI = feed.tracks.first?.uri
            feeds[seed] = feed
            BopifyLog.library.debug("explore authorized library candidates count=\(feed.librarySuggestions.count, privacy: .public)")
        }
        guard let feed = feeds[seed] else { return }
        if feed.hasLoaded, !appending {
            BopifyLog.library.debug("explore feed cache hit")
            scheduleAutomaticRetry(for: seed)
            return
        }
        let remaining = feed.candidateSeeds.filter { !feed.attempted.contains($0) }
        await requestCandidates(Array(remaining.prefix(3)), for: seed)
    }

    private func requestCandidates(_ seeds: [SpotifyURI], for seed: SpotifyURI) async {
        guard visible, selectedSeed == seed, !seeds.isEmpty, loadingSeed != seed else { return }
        cancelAutomaticRetry()
        station?.cancel()
        loadingSeed = seed
        let current = generation
        BopifyLog.library.debug("explore candidate batch requesting count=\(seeds.count, privacy: .public)")
        let task = Task { [self] in
            let results = await withTaskGroup(of: Candidate.self, returning: [Candidate].self) { group in
                var results: [SpotifyURI: Candidate] = [:]
                for candidateSeed in seeds {
                    if let cached = mixes[candidateSeed] {
                        let candidate = Candidate(seed: candidateSeed, result: .success(cached))
                        results[candidateSeed] = candidate
                        publishInitialWindow(candidate, for: seed, generation: current)
                    } else {
                        group.addTask { [self] in await requestCandidate(candidateSeed) }
                    }
                }
                for await result in group {
                    results[result.seed] = result
                    publishInitialWindow(result, for: seed, generation: current)
                }
                return seeds.compactMap { results[$0] }
            }
            guard !Task.isCancelled, generation == current, selectedSeed == seed, visible,
                  var feed = feeds[seed] else { return }
            var candidates: [[Track]] = []
            for result in results {
                feed.attempted.insert(result.seed)
                switch result.result {
                case let .success(mix):
                    mixes[result.seed] = mix.tracks.isEmpty ? nil : mix
                    feed.failures[result.seed] = mix.tracks.isEmpty ? .noMix : nil
                    candidates.append(mix.tracks)
                case let .failure(failure):
                    feed.failures[result.seed] = failure
                    BopifyLog.library.notice("explore candidate failed reason=\(failure.rawValue, privacy: .public)")
                }
            }
            feed.tracks.append(contentsOf: ExploreDiscovery.rank(candidates: candidates, recentlyPlayed: recentlyPlayed,
                                                                 excluding: Set(feed.tracks.map(\.uri)), preceding: feed.tracks))
            if !feed.hasRadioCandidates {
                feed.tracks.append(contentsOf: ExploreDiscovery.rank(candidates: [feed.librarySuggestions], recentlyPlayed: recentlyPlayed,
                                                                     excluding: Set(feed.tracks.map(\.uri)), preceding: feed.tracks))
            }
            if feed.selectedURI == nil { feed.selectedURI = feed.tracks.first?.uri }
            feed.hasLoaded = true
            feeds[seed] = feed
            BopifyLog.library.debug("explore feed updated count=\(feed.tracks.count, privacy: .public)")
            stationFailures[seed] = feed.tracks.isEmpty ? feed.candidateSeeds.compactMap { feed.failures[$0] }.first : nil
            if loadingSeed == seed { loadingSeed = nil }
            station = nil
            if !feed.hasRadioCandidates,
               !feed.failures.values.contains(where: { $0 == .network || $0 == .unavailable }),
               feed.candidateSeeds.contains(where: { !feed.attempted.contains($0) }) {
                await openSelectedStation(appending: true)
            } else {
                scheduleAutomaticRetry(for: seed)
            }
        }
        station = task
        await task.value
    }

    /// Show a useful first window without letting a slow radio hold the entire shelf empty.
    private func publishInitialWindow(_ candidate: Candidate, for seed: SpotifyURI, generation current: Int) {
        guard !Task.isCancelled, visible, generation == current, selectedSeed == seed,
              var feed = feeds[seed], case let .success(mix) = candidate.result, !mix.tracks.isEmpty else { return }
        feed.hasRadioCandidates = true
        if !feed.tracks.isEmpty {
            feeds[seed] = feed
            stationFailures[seed] = nil
            return
        }
        let initial = Array(ExploreDiscovery.rank(candidates: [mix.tracks], recentlyPlayed: recentlyPlayed,
                                                 excluding: []).prefix(3))
        guard !initial.isEmpty else { return }
        feed.tracks = initial
        feed.selectedURI = initial.first?.uri
        feeds[seed] = feed
        stationFailures[seed] = nil
    }

    private func requestCandidate(_ seed: SpotifyURI) async -> Candidate {
        do {
            try Task.checkCancellation()
            return Candidate(seed: seed, result: .success(try await radio(seed)))
        } catch {
            return Candidate(seed: seed, result: .failure(error as? RadioFailure ?? .unavailable))
        }
    }

    private func cancelStationRequest() {
        station?.cancel()
        station = nil
        loadingSeed = nil
    }

    private func cancelAutomaticRetry() {
        automaticRetry?.cancel()
        automaticRetry = nil
        retryID = nil
    }

    private func scheduleAutomaticRetry(for seed: SpotifyURI) {
        guard visible, selectedSeed == seed, automaticRetry == nil, let feed = feeds[seed],
              feed.failures.values.contains(where: { $0 == .network || $0 == .unavailable }) else { return }
        let delays: [Duration] = [.seconds(2), .seconds(5), .seconds(15)]
        let count = feed.retries
        guard count < delays.count else { return }
        let id = UUID(), current = generation, delay = delays[count]
        retryID = id
        BopifyLog.library.debug("explore station retry scheduled attempt=\(count + 1, privacy: .public)")
        automaticRetry = Task { [weak self, retrySleep] in
            do { try await retrySleep(delay) } catch { return }
            guard let self, !Task.isCancelled, retryID == id, generation == current,
                  visible, selectedSeed == seed else { return }
            automaticRetry = nil
            retryID = nil
            guard let feed = feeds[seed] else { return }
            feeds[seed]?.retries = count + 1
            let retrying = feed.candidateSeeds.filter { feed.failures[$0] == .network || feed.failures[$0] == .unavailable }
            await requestCandidates(Array(retrying.prefix(3)), for: seed)
        }
    }
}
