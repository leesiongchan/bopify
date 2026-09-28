import Foundation
import Observation
import os
import BopifyDomain

@MainActor @Observable
public final class LikedSongsModel {
    public private(set) var tracks: [Track] = []
    public private(set) var selectedURI: SpotifyURI?
    public private(set) var isLoading = false
    public private(set) var error: LibraryError?
    public private(set) var retryAfter: Date?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let service: any SavedTracksService
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var visible = false
    @ObservationIgnored private var hiddenAt: Date?
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var needsRefresh = false
    @ObservationIgnored private var nextOffset: Int?
    @ObservationIgnored private var loadedPrefix = 0
    @ObservationIgnored private var failedRefresh = true

    public convenience init(service: any SavedTracksService) { self.init(service: service, now: Date.init) }
    init(service: any SavedTracksService, now: @escaping () -> Date) { self.service = service; self.now = now }
    public var hasMore: Bool { nextOffset != nil }
    public func loadMore() async {
        guard visible, !isLoading, error == nil, nextOffset != nil else { return }
        await request(refresh: false)
    }

    public func reveal(at date: Date) async {
        visible = true
        let stale = hiddenAt.map { date.timeIntervalSince($0) >= 60 } ?? false
        hiddenAt = nil
        guard !isLoading, error == nil, needsRefresh || stale || !loaded else { return }
        await request(refresh: true)
    }

    public func hide(at date: Date) {
        if visible { hiddenAt = date }
        visible = false
    }

    public func select(_ uri: SpotifyURI) {
        guard tracks.contains(where: { $0.uri == uri }) else { return }
        selectedURI = uri
    }

    public func loadMoreIfNeeded(near uri: SpotifyURI) async {
        guard visible, !isLoading, error == nil, nextOffset != nil,
              let index = tracks.firstIndex(where: { $0.uri == uri }), index >= tracks.count - 5 else { return }
        await loadMore()
    }

    public func refresh() async {
        needsRefresh = true
        guard visible, retryAfter.map({ $0 <= now() }) ?? true else { return }
        await request(refresh: true)
    }

    public func retry(at date: Date) async {
        guard visible, !isLoading, error != nil, retryAfter.map({ $0 <= date }) ?? true else { return }
        await request(refresh: failedRefresh)
    }

    public func clear() {
        generation += 1
        pending?.cancel()
        visible = false
        hiddenAt = nil
        tracks = []
        selectedURI = nil
        loaded = false
        loadedPrefix = 0
        nextOffset = nil
        isLoading = false
        error = nil
        retryAfter = nil
        needsRefresh = false
        BopifyLog.library.debug("liked songs cleared")
    }

    private func request(refresh: Bool) async {
        let previous = pending
        previous?.cancel()
        generation += 1
        let current = generation
        let targetPrefix = max(50, loadedPrefix)
        isLoading = true
        error = nil
        retryAfter = nil
        failedRefresh = refresh
        let task = Task {
            // A cancelled service may still finish; serialize actual requests as well as state writes.
            await previous?.value
            guard generation == current, !Task.isCancelled else { return }
            defer {
                if generation == current { isLoading = false; pending = nil }
            }
            var offset = refresh ? 0 : (nextOffset ?? 0)
            var replacement = refresh ? [] : tracks
            var seen = Set(replacement.map(\.uri))
            do {
                while true {
                    BopifyLog.library.debug("liked songs page offset=\(offset, privacy: .public)")
                    let page = try await service.savedTracks(offset: offset, limit: 50)
                    guard generation == current, !Task.isCancelled else { return }
                    if let next = page.nextOffset, next <= offset { throw LibraryError.invalidResponse }
                    replacement.append(contentsOf: page.tracks.filter { seen.insert($0.uri).inserted })
                    let prefix = page.nextOffset ?? (offset + 50)
                    if refresh, let next = page.nextOffset, next < targetPrefix {
                        guard visible else { needsRefresh = true; return }
                        offset = next
                        continue
                    }
                    let oldIndex = tracks.firstIndex { $0.uri == selectedURI } ?? 0
                    if !replacement.contains(where: { $0.uri == selectedURI }) {
                        selectedURI = replacement.isEmpty ? nil : replacement[min(oldIndex, replacement.count - 1)].uri
                    }
                    tracks = replacement
                    nextOffset = page.nextOffset
                    loadedPrefix = prefix
                    loaded = true
                    needsRefresh = false
                    BopifyLog.library.debug("liked songs page ready count=\(self.tracks.count, privacy: .public)")
                    return
                }
            } catch {
                guard generation == current, !Task.isCancelled else { return }
                let failure = error as? LibraryError ?? .unavailable
                self.error = failure
                if case let .rateLimited(seconds) = failure {
                    retryAfter = now().addingTimeInterval(TimeInterval(seconds ?? 60))
                } else if case let .quotaExceeded(seconds) = failure {
                    retryAfter = now().addingTimeInterval(TimeInterval(seconds ?? 60))
                }
                BopifyLog.library.notice("liked songs request failed")
            }
        }
        pending = task
        await task.value
    }
}
