import Foundation
import Observation
import os
import BopifyDomain

@MainActor @Observable
public final class SavedCollectionsModel: CoverFlowSource {
    public private(set) var kind: LibraryCollectionKind = .playlists
    public private(set) var items: [LibraryCollection] = []
    public private(set) var selectedURI: SpotifyURI?
    public private(set) var isLoading = false
    public private(set) var error: LibraryError?
    public private(set) var retryAfter: Date?
    public var hasMore: Bool { nextOffset != nil }
    @ObservationIgnored private let service: any LibraryCollectionsService
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var reveals = 0
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var nextOffset: Int?
    @ObservationIgnored private var failedOffset = 0

    public init(service: any LibraryCollectionsService) { self.service = service }

    public func reveal(at date: Date) async {
        reveals += 1
        guard !loaded, !isLoading, error == nil else { return }
        await load(offset: 0)
    }
    public func hide(at date: Date) { reveals = max(0, reveals - 1) }

    public func selectKind(_ kind: LibraryCollectionKind) async {
        guard kind != self.kind else { return }
        clear()
        self.kind = kind
        BopifyLog.library.debug("collection kind changed kind=\(kind.rawValue, privacy: .public)")
        if reveals > 0 { await load(offset: 0) }
    }

    public func select(_ uri: SpotifyURI) {
        guard items.contains(where: { $0.uri == uri }) else { return }
        selectedURI = uri
    }

    public func loadMore() async {
        guard reveals > 0, !isLoading, error == nil, let nextOffset else { return }
        await load(offset: nextOffset)
    }
    public func loadMoreIfNeeded(near uri: SpotifyURI) async {
        guard let index = items.firstIndex(where: { $0.uri == uri }), index >= items.count - 5 else { return }
        await loadMore()
    }
    public func retry(at date: Date) async {
        guard reveals > 0, !isLoading, error != nil, retryAfter.map({ $0 <= date }) ?? true else { return }
        await load(offset: failedOffset)
    }
    public func refresh() async {
        generation += 1
        loaded = false
        isLoading = false
        error = nil
        retryAfter = nil
        if reveals > 0 { await load(offset: 0) }
    }

    public func clear() {
        generation += 1
        items = []
        selectedURI = nil
        isLoading = false
        error = nil
        retryAfter = nil
        loaded = false
        nextOffset = nil
        failedOffset = 0
    }

    public func playRequest(for item: LibraryCollection) -> PlayRequest { PlayRequest(contextURI: item.uri) }

    private func load(offset: Int) async {
        let current = generation
        isLoading = true
        error = nil
        retryAfter = nil
        failedOffset = offset
        defer { if generation == current { isLoading = false } }
        BopifyLog.library.debug("collections page loading kind=\(self.kind.rawValue, privacy: .public) offset=\(offset, privacy: .public)")
        do {
            let page = try await service.savedCollections(kind, offset: offset, limit: 50)
            guard generation == current, !Task.isCancelled else { return }
            if let next = page.nextOffset, next <= offset { throw LibraryError.invalidResponse }
            var replacement = offset == 0 ? [] : items
            var seen = Set(replacement.map(\.uri))
            replacement.append(contentsOf: page.items.filter { seen.insert($0.uri).inserted })
            items = replacement
            nextOffset = page.nextOffset
            loaded = true
            if !items.contains(where: { $0.uri == selectedURI }) { selectedURI = items.first?.uri }
            BopifyLog.library.debug("collections ready count=\(self.items.count, privacy: .public)")
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
            BopifyLog.library.notice("collections request failed")
        }
    }
}
