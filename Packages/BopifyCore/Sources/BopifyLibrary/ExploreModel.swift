import Foundation
import Observation
import os
import BopifyDomain

/// Station chips seeded from the user's top tracks and artists; each opens Spotify's radio mix for its seed.
@MainActor @Observable
public final class ExploreModel: CoverFlowSource {
    public private(set) var chips: [StationSeed] = []
    public private(set) var selectedSeed: SpotifyURI?
    public private(set) var stationFailures: [SpotifyURI: RadioFailure] = [:]
    public private(set) var error: LibraryError?
    public private(set) var retryAfter: Date?
    private var isLoadingChips = false
    private var loadingSeed: SpotifyURI?
    private var mixes: [SpotifyURI: RadioMix] = [:]
    private var selections: [SpotifyURI: SpotifyURI] = [:]
    @ObservationIgnored private let history: any ListeningHistoryService
    @ObservationIgnored private let savedTracks: any SavedTracksService
    @ObservationIgnored private let radio: @MainActor (SpotifyURI) async throws -> RadioMix
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var chipsLoadedAt: Date?
    // Counted, not a flag: on a quick tab round trip the old view's hide can land after the new view's reveal.
    @ObservationIgnored private var reveals = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var station: Task<Void, Never>?

    public var isLoading: Bool { isLoadingChips || loadingSeed != nil }
    public var hasMore: Bool { false }
    private var visible: Bool { reveals > 0 }
    public var tracks: [Track] { selectedSeed.flatMap { mixes[$0]?.tracks } ?? [] }
    public var selectedURI: SpotifyURI? { selectedSeed.flatMap { selections[$0] } }
    public var stationFailure: RadioFailure? { selectedSeed.flatMap { stationFailures[$0] } }

    public convenience init(history: any ListeningHistoryService, savedTracks: any SavedTracksService,
                            radio: @escaping @MainActor (SpotifyURI) async throws -> RadioMix) {
        self.init(history: history, savedTracks: savedTracks, radio: radio, now: Date.init)
    }
    init(history: any ListeningHistoryService, savedTracks: any SavedTracksService,
         radio: @escaping @MainActor (SpotifyURI) async throws -> RadioMix, now: @escaping () -> Date) {
        self.history = history
        self.savedTracks = savedTracks
        self.radio = radio
        self.now = now
    }

    public func reveal(at date: Date) async {
        reveals += 1
        guard !isLoadingChips, retryAfter.map({ $0 <= date }) ?? true else { return }
        if error == nil, let chipsLoadedAt, date.timeIntervalSince(chipsLoadedAt) < 6 * 60 * 60 {
            BopifyLog.library.debug("explore chips cache hit")
            await openSelectedStation()
            return
        }
        await loadChips()
    }

    public func hide(at date: Date) { reveals = max(0, reveals - 1) }

    public func select(_ uri: SpotifyURI) {
        guard let seed = selectedSeed, tracks.contains(where: { $0.uri == uri }) else { return }
        selections[seed] = uri
    }

    public func selectChip(_ seed: SpotifyURI) async {
        guard seed != selectedSeed, chips.contains(where: { $0.uri == seed }) else { return }
        selectedSeed = seed
        BopifyLog.library.debug("explore chip selected")
        await openSelectedStation()
    }

    public func retryStation() async {
        guard let seed = selectedSeed, stationFailures[seed] != nil else { return }
        stationFailures[seed] = nil
        await openSelectedStation()
    }

    public func loadMore() async {}
    public func loadMoreIfNeeded(near uri: SpotifyURI) async {}

    public func retry(at date: Date) async {
        guard visible, !isLoadingChips, error != nil, retryAfter.map({ $0 <= date }) ?? true else { return }
        await loadChips()
    }

    /// After consent: reloads now when shown, otherwise on the next reveal.
    public func refresh() async {
        chipsLoadedAt = nil
        guard visible, !isLoadingChips else { return }
        await loadChips()
    }

    public func clear() {
        generation += 1
        station?.cancel()
        station = nil
        chips = []
        selectedSeed = nil
        stationFailures = [:]
        isLoadingChips = false
        loadingSeed = nil
        mixes = [:]
        selections = [:]
        error = nil
        retryAfter = nil
        chipsLoadedAt = nil
        BopifyLog.library.debug("explore cleared")
    }

    public func playRequest(for track: Track) -> PlayRequest {
        guard let seed = selectedSeed, let mix = mixes[seed] else { return PlayRequest(contextURI: track.uri) }
        return PlayRequest(contextURI: mix.contextURI, startTrackURI: track.uri)
    }

    /// Alternates tracks and artists so both kinds lead, without repeats, ten at most.
    static func interleave(_ tracks: [StationSeed], _ artists: [StationSeed]) -> [StationSeed] {
        var seen = Set<SpotifyURI>()
        var result: [StationSeed] = []
        for index in 0..<max(tracks.count, artists.count) {
            for list in [tracks, artists] where index < list.count && seen.insert(list[index].uri).inserted {
                result.append(list[index])
            }
        }
        return Array(result.prefix(10))
    }

    private func loadChips() async {
        generation += 1
        let current = generation
        isLoadingChips = true
        error = nil
        retryAfter = nil
        // Covers the cancelled and superseded early returns; the flag is also cleared before the station step.
        defer { if generation == current { isLoadingChips = false } }
        BopifyLog.library.debug("explore chips cache miss, loading")
        do {
            var seeds = Self.interleave(try await history.topItems(.tracks), try await history.topItems(.artists))
            if seeds.isEmpty {
                // Liked songs are only a fallback; without that consent Explore just has no chips.
                // Any other failure is a real error, so it is shown and retried rather than cached as empty.
                let liked: [Track]
                do {
                    liked = try await savedTracks.savedTracks(offset: 0, limit: 5).tracks
                } catch LibraryError.authorizationRequired, LibraryError.forbidden {
                    liked = []
                }
                seeds = liked.map { StationSeed(uri: $0.uri, name: $0.title) }
                BopifyLog.library.debug("explore chips from liked songs count=\(seeds.count, privacy: .public)")
            }
            guard generation == current, !Task.isCancelled else { return }
            chips = seeds
            chipsLoadedAt = now()
            if !seeds.contains(where: { $0.uri == selectedSeed }) { selectedSeed = seeds.first?.uri }
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

    /// One station request at a time: choosing another chip cancels the one in flight and drops its result.
    private func openSelectedStation() async {
        guard let seed = selectedSeed else { return }
        if mixes[seed] != nil {
            BopifyLog.library.debug("explore station cache hit")
            return
        }
        guard stationFailures[seed] == nil, loadingSeed != seed else { return }
        station?.cancel()
        loadingSeed = seed
        BopifyLog.library.debug("explore station cache miss, requesting")
        let task = Task { [self] in
            do {
                let mix = try await radio(seed)
                guard !Task.isCancelled else { return }
                mixes[seed] = mix
                if selections[seed] == nil { selections[seed] = mix.tracks.first?.uri }
            } catch {
                guard !Task.isCancelled else { return }
                stationFailures[seed] = error as? RadioFailure ?? .unavailable
                BopifyLog.library.notice("explore station request failed")
            }
            if loadingSeed == seed { loadingSeed = nil }
        }
        station = task
        await task.value
    }
}
