import Foundation
import Observation
import os
import BopifyDomain

@MainActor @Observable
public final class SavedCollectionsModel: CoverFlowSource {
    public private(set) var items: [LibraryCollection] = []
    public private(set) var selectedURI: SpotifyURI?
    public private(set) var isLoading = false
    public private(set) var error: LibraryError?
    public private(set) var retryAfter: Date?
    public var hasMore: Bool { !nextCursors.isEmpty }
    @ObservationIgnored private let service: any LibraryCollectionsService
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var reveals = 0
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var nextCursors: [LibraryCollectionKind: LibraryCollectionCursor] = [.playlists: .offset(0), .albums: .offset(0), .artists: .after(nil)]
    @ObservationIgnored private var pendingKinds = LibraryCollectionKind.allCases

    public init(service: any LibraryCollectionsService) { self.service = service }

    public func reveal(at date: Date) async {
        reveals += 1
        guard !loaded, !isLoading, error == nil else { return }
        await load()
    }
    public func hide(at date: Date) { reveals = max(0, reveals - 1) }

    public func select(_ uri: SpotifyURI) {
        guard items.contains(where: { $0.uri == uri }) else { return }
        selectedURI = uri
    }

    public func loadMore() async {
        guard reveals > 0, !isLoading, error == nil, hasMore else { return }
        await load()
    }
    public func loadMoreIfNeeded(near uri: SpotifyURI) async {
        guard let index = items.firstIndex(where: { $0.uri == uri }), index >= items.count - 5 else { return }
        await loadMore()
    }
    public func retry(at date: Date) async {
        guard reveals > 0, !isLoading, error != nil, retryAfter.map({ $0 <= date }) ?? true else { return }
        await load()
    }
    public func clear() {
        generation += 1
        items = []
        selectedURI = nil
        isLoading = false
        error = nil
        retryAfter = nil
        loaded = false
        nextCursors = [.playlists: .offset(0), .albums: .offset(0), .artists: .after(nil)]
        pendingKinds = LibraryCollectionKind.allCases
    }

    public func playRequest(for item: LibraryCollection) -> PlayRequest { PlayRequest(contextURI: item.uri) }

    private func load() async {
        let current = generation
        isLoading = true
        error = nil
        retryAfter = nil
        defer {
            if generation == current {
                isLoading = false
                if pendingKinds.isEmpty { pendingKinds = LibraryCollectionKind.allCases.filter { nextCursors[$0] != nil } }
                if !items.contains(where: { $0.uri == selectedURI }) { selectedURI = items.first?.uri }
            }
        }
        for kind in pendingKinds {
            do {
                guard let cursor = nextCursors[kind] else { continue }
                BopifyLog.library.debug("collections page loading kind=\(kind.rawValue, privacy: .public)")
                let page = try await service.savedCollections(kind, cursor: cursor, limit: 50)
                guard generation == current, !Task.isCancelled else { return }
                if let next = page.nextCursor {
                    guard next != cursor else { throw LibraryError.invalidResponse }
                    switch (cursor, next) {
                    case (.after, .after(let id)) where kind == .artists && id?.isEmpty == false: break
                    case (.offset(let old), .offset(let new)) where kind != .artists && new > old: break
                    default: throw LibraryError.invalidResponse
                    }
                }
                var replacement = loaded ? items : []
                var seen = Set(replacement.map(\.uri))
                replacement.append(contentsOf: page.items.filter { seen.insert($0.uri).inserted })
                items = replacement
                nextCursors[kind] = page.nextCursor
                pendingKinds.removeAll { $0 == kind }
                loaded = true
            } catch is CancellationError {
                return
            } catch {
                guard generation == current, !Task.isCancelled else { return }
                let failure = error as? LibraryError ?? .unavailable
                self.error = failure
                BopifyLog.library.notice("collections request failed kind=\(kind.rawValue, privacy: .public)")
                switch failure {
                case let .rateLimited(seconds), let .quotaExceeded(seconds):
                    retryAfter = Date().addingTimeInterval(TimeInterval(seconds ?? 60))
                    return
                case .authorizationRequired: return
                default: break
                }
            }
        }
        BopifyLog.library.debug("collections ready count=\(self.items.count, privacy: .public)")
    }
}
