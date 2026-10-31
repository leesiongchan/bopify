import Foundation
import Observation
import os
import BopifyDomain

/// Recently played tracks, newest first with repeats collapsed to their newest play.
@MainActor @Observable
public final class RecentsModel: CoverFlowSource {
    public private(set) var tracks: [Track] = []
    public private(set) var selectedURI: SpotifyURI?
    public private(set) var isLoading = false
    public private(set) var error: LibraryError?
    public private(set) var retryAfter: Date?
    public var hasMore: Bool { false }
    private var visible: Bool { reveals > 0 }
    @ObservationIgnored private let service: any ListeningHistoryService
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var contexts: [SpotifyURI: SpotifyURI] = [:]
    @ObservationIgnored private var loadedAt: Date?
    // Counted, not a flag: on a quick tab round trip the old view's hide can land after the new view's reveal.
    @ObservationIgnored private var reveals = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var pending: Task<Void, Never>?

    public convenience init(service: any ListeningHistoryService) { self.init(service: service, now: Date.init) }
    init(service: any ListeningHistoryService, now: @escaping () -> Date) {
        self.service = service
        self.now = now
    }

    public func reveal(at date: Date) async {
        reveals += 1
        if let pending { await pending.value; return }
        guard !isLoading, retryAfter.map({ $0 <= date }) ?? true else { return }
        if error == nil, let loadedAt, date.timeIntervalSince(loadedAt) < 60 {
            BopifyLog.library.debug("recents cache hit")
            return
        }
        await load()
    }

    public func hide(at date: Date) { reveals = max(0, reveals - 1) }

    public func select(_ uri: SpotifyURI) {
        guard tracks.contains(where: { $0.uri == uri }) else { return }
        selectedURI = uri
    }

    public func loadMore() async {}
    public func loadMoreIfNeeded(near uri: SpotifyURI) async {}

    public func retry(at date: Date) async {
        guard visible, !isLoading, error != nil, retryAfter.map({ $0 <= date }) ?? true else { return }
        await load()
    }

    public func clear() {
        generation += 1
        pending?.cancel()
        pending = nil
        tracks = []
        selectedURI = nil
        contexts = [:]
        loadedAt = nil
        isLoading = false
        error = nil
        retryAfter = nil
        BopifyLog.library.debug("recents cleared")
    }

    /// Plays from the context Spotify reported for that play, else the track alone.
    public func playRequest(for track: Track) -> PlayRequest {
        guard let context = contexts[track.uri] else { return PlayRequest(contextURI: track.uri) }
        return PlayRequest(contextURI: context, startTrackURI: track.uri)
    }

    private func load() async {
        generation += 1
        let current = generation
        isLoading = true
        error = nil
        retryAfter = nil
        // A shelf fetch belongs to the cache, so replacing its view must not discard the in-flight result.
        let task = Task { await receive(generation: current) }
        pending = task
        await task.value
    }

    private func receive(generation current: Int) async {
        defer { if generation == current { isLoading = false; pending = nil } }
        guard generation == current, !Task.isCancelled else { return }
        BopifyLog.library.debug("recents cache miss, loading")
        do {
            let plays = try await service.recentlyPlayed()
            guard generation == current, !Task.isCancelled else { return }
            var seen = Set<SpotifyURI>()
            let newest = plays.filter { seen.insert($0.track.uri).inserted }
            contexts = Dictionary(uniqueKeysWithValues: newest.compactMap { play in play.contextURI.map { (play.track.uri, $0) } })
            tracks = newest.map(\.track)
            if !tracks.contains(where: { $0.uri == selectedURI }) { selectedURI = tracks.first?.uri }
            loadedAt = now()
            BopifyLog.library.info("recents ready received=\(plays.count, privacy: .public) distinct=\(self.tracks.count, privacy: .public) repeats=\(plays.count - newest.count, privacy: .public)")
        } catch {
            guard generation == current, !Task.isCancelled else { return }
            let failure = error as? LibraryError ?? .unavailable
            self.error = failure
            switch failure {
            case let .rateLimited(seconds), let .quotaExceeded(seconds):
                retryAfter = now().addingTimeInterval(TimeInterval(seconds ?? 60))
            default: break
            }
            BopifyLog.library.notice("recents request failed")
        }
    }
}
