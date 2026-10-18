import Foundation
import Observation
import os
import BopifyDomain

@MainActor @Observable
public final class SearchModel {
    public private(set) var query = ""
    public private(set) var tracks: [Track] = []
    public private(set) var selectedURI: SpotifyURI?
    public private(set) var isLoading = false
    public private(set) var error: LibraryError?
    public private(set) var retryAfter: Date?
    public var hasMore: Bool { nextOffset != nil }
    @ObservationIgnored private let service: any TrackSearchService
    @ObservationIgnored private let debounce: @Sendable () async throws -> Void
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var nextOffset: Int?
    @ObservationIgnored private var failedOffset = 0
    @ObservationIgnored private var request: Task<TrackSearchPage, Error>?

    public convenience init(service: any TrackSearchService) {
        self.init(service: service, debounce: { try await Task.sleep(for: .milliseconds(300)) })
    }
    init(service: any TrackSearchService, debounce: @escaping @Sendable () async throws -> Void) {
        self.service = service; self.debounce = debounce
    }

    public func updateQuery(_ value: String) {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value != query else { return }
        clear()
        query = value
        isLoading = !value.isEmpty
    }

    public func search() async {
        guard !query.isEmpty else { return }
        generation += 1
        let current = generation
        isLoading = true
        defer { if generation == current { isLoading = false } }
        do { try await debounce() } catch { return }
        guard generation == current, !Task.isCancelled else { return }
        await load(offset: 0, generation: current)
    }

    public func loadMore() async {
        guard !isLoading, error == nil, let nextOffset else { return }
        await load(offset: nextOffset, generation: generation)
    }

    public func retry(at date: Date) async {
        guard !query.isEmpty, !isLoading, error != nil, retryAfter.map({ $0 <= date }) ?? true else { return }
        await load(offset: failedOffset, generation: generation)
    }

    public func select(_ uri: SpotifyURI) {
        guard tracks.contains(where: { $0.uri == uri }) else { return }
        selectedURI = uri
    }

    public func moveSelection(by delta: Int) {
        guard !tracks.isEmpty else { return }
        let index = tracks.firstIndex { $0.uri == selectedURI } ?? 0
        selectedURI = tracks[min(tracks.count - 1, max(0, index + delta))].uri
    }

    public func playRequest(for track: Track) -> PlayRequest? {
        guard tracks.contains(where: { $0.uri == track.uri }) else { return nil }
        return PlayRequest(contextURI: track.uri)
    }

    public func clear() {
        generation += 1
        request?.cancel()
        request = nil
        query = ""
        tracks = []
        selectedURI = nil
        nextOffset = nil
        failedOffset = 0
        error = nil
        retryAfter = nil
        isLoading = false
    }

    private func load(offset: Int, generation current: Int) async {
        let query = query
        isLoading = true
        error = nil
        retryAfter = nil
        failedOffset = offset
        defer { if generation == current { isLoading = false; request = nil } }
        BopifyLog.library.debug("catalog search page loading offset=\(offset, privacy: .public)")
        do {
            let service = service
            let task = Task { try await service.searchTracks(query: query, offset: offset, limit: 10) }
            request = task
            let page = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            guard generation == current, !Task.isCancelled else { return }
            if let next = page.nextOffset, next <= offset { throw LibraryError.invalidResponse }
            var replacement = offset == 0 ? [] : tracks
            var seen = Set(replacement.map(\.uri))
            replacement.append(contentsOf: page.tracks.filter { seen.insert($0.uri).inserted })
            tracks = replacement
            nextOffset = page.nextOffset
            if !tracks.contains(where: { $0.uri == selectedURI }) { selectedURI = tracks.first?.uri }
            BopifyLog.library.debug("catalog search ready count=\(self.tracks.count, privacy: .public)")
        } catch is CancellationError {
        } catch {
            guard generation == current, !Task.isCancelled else { return }
            let failure = error as? LibraryError ?? .unavailable
            self.error = failure
            switch failure {
            case let .rateLimited(seconds), let .quotaExceeded(seconds):
                retryAfter = Date().addingTimeInterval(TimeInterval(seconds ?? 60))
            default: break
            }
            BopifyLog.library.notice("catalog search failed")
        }
    }
}
