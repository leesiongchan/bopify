import Foundation
import Observation
import os
import BopifyDomain
import FuzzyMatch

public struct CatalogSearchGroup: Equatable, Sendable {
    public let kind: CatalogSearchKind
    public fileprivate(set) var results: [CatalogSearchResult] = []
    public fileprivate(set) var nextOffset: Int?
    public fileprivate(set) var isLoading = false
    public fileprivate(set) var error: LibraryError?
    public fileprivate(set) var retryAfter: Date?
    public var hasMore: Bool { nextOffset != nil }
}

@MainActor @Observable
public final class SearchModel {
    public private(set) var query = ""
    public private(set) var groups = CatalogSearchKind.allCases.map { CatalogSearchGroup(kind: $0) }
    public var results: [CatalogSearchResult] {
        let items = groups.flatMap(\.results)
        // Music titles use literal text similarity rather than code identifier acronyms or subsequences.
        let matcher = FuzzyMatcher(config: MatchConfig(algorithm: .editDistance(EditDistanceConfig(
            acronymWeight: 0, isSubsequenceMatchingEnabled: false))))
        let prepared = matcher.prepare(normalized(query))
        var buffer = matcher.makeBuffer()
        let ranked = items.enumerated().map { index, result in
            (index: index, result: result,
             score: matcher.score(normalized(result.title), against: prepared, buffer: &buffer)?.score)
        }
        return ranked.sorted { lhs, rhs in
            if lhs.score != rhs.score { return (lhs.score ?? -.infinity) > (rhs.score ?? -.infinity) }
            return lhs.index < rhs.index
        }.map { $0.result }
    }
    public private(set) var hasSearched = false
    public private(set) var selectedURI: SpotifyURI?
    public private(set) var isLoading = false
    public private(set) var error: LibraryError?
    public private(set) var retryAfter: Date?
    public var canRetry: Bool {
        switch error {
        case .invalidLink, .unsupportedLink, .notFound, .authorizationRequired, nil: false
        default: true
        }
    }
    @ObservationIgnored private let service: any CatalogSearchService
    @ObservationIgnored private let debounce: @Sendable () async throws -> Void
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var initialRequest: Task<[CatalogSearchKind: CatalogSearchPage], Error>?
    @ObservationIgnored private var requests: [CatalogSearchKind: Task<[CatalogSearchKind: CatalogSearchPage], Error>] = [:]

    public convenience init(service: any CatalogSearchService) {
        self.init(service: service, debounce: { try await Task.sleep(for: .milliseconds(300)) })
    }
    init(service: any CatalogSearchService, debounce: @escaping @Sendable () async throws -> Void,
         now: @escaping @Sendable () -> Date = Date.init) {
        self.service = service; self.debounce = debounce; self.now = now
    }

    public func updateQuery(_ value: String) {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value != query else { return }
        clear()
        query = value
        isLoading = !value.isEmpty
    }

    public func search() async {
        guard !query.isEmpty, !hasSearched, initialRequest == nil, requestsAllowed(at: now()) else { return }
        generation += 1
        let current = generation
        isLoading = true
        defer { if generation == current { isLoading = false } }
        do { try await debounce() } catch { return }
        guard generation == current, !Task.isCancelled else { return }
        await load(kind: nil, offset: 0, generation: current)
    }

    public func loadMore() async {
        guard hasSearched, !isLoading, !groups.contains(where: \.isLoading), requestsAllowed(at: now()) else { return }
        let current = generation
        let kinds = groups.filter { $0.hasMore && $0.error == nil }.map(\.kind)
        await withTaskGroup(of: Void.self) { tasks in
            for kind in kinds {
                tasks.addTask { await self.loadMore(kind, generation: current) }
            }
        }
    }

    private func loadMore(_ kind: CatalogSearchKind, generation current: Int) async {
        guard generation == current, !Task.isCancelled else { return }
        await loadMore(kind)
    }

    public func loadMore(_ kind: CatalogSearchKind) async {
        guard hasSearched, !isLoading, requestsAllowed(at: now()),
              let group = groups.first(where: { $0.kind == kind }),
              !group.isLoading, group.error == nil, let offset = group.nextOffset else { return }
        await load(kind: kind, offset: offset, generation: generation)
    }

    public func retry(at date: Date) async {
        guard !query.isEmpty, !isLoading, canRetry, requestsAllowed(at: date) else { return }
        await load(kind: nil, offset: 0, generation: generation)
    }

    public func retry(_ kind: CatalogSearchKind, at date: Date) async {
        guard !isLoading, requestsAllowed(at: date),
              let group = groups.first(where: { $0.kind == kind }),
              !group.isLoading, group.error != nil, let offset = group.nextOffset else { return }
        await load(kind: kind, offset: offset, generation: generation)
    }

    public func select(_ uri: SpotifyURI) {
        guard results.contains(where: { $0.uri == uri }) else { return }
        selectedURI = uri
    }

    public func moveSelection(by delta: Int) {
        let items = results
        guard !items.isEmpty, delta != 0 else { return }
        let index = items.firstIndex { $0.uri == selectedURI } ?? (delta > 0 ? -1 : items.count)
        selectedURI = items[min(items.count - 1, max(0, index + delta))].uri
    }

    public func playRequest(for result: CatalogSearchResult) -> PlayRequest? {
        guard results.contains(where: { $0.uri == result.uri }) else { return nil }
        return PlayRequest(contextURI: result.uri)
    }

    public func cancel() {
        generation += 1
        initialRequest?.cancel()
        initialRequest = nil
        requests.values.forEach { $0.cancel() }
        requests = [:]
        isLoading = false
        for index in groups.indices { groups[index].isLoading = false }
    }

    public func clear() {
        cancel()
        query = ""
        groups = CatalogSearchKind.allCases.map { CatalogSearchGroup(kind: $0) }
        selectedURI = nil
        hasSearched = false
        error = nil
        retryAfter = nil
    }

    private func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                      locale: Locale(identifier: "en_US_POSIX"))
    }

    private func requestsAllowed(at date: Date) -> Bool {
        retryAfter.map { $0 <= date } ?? true
    }

    private func load(kind: CatalogSearchKind?, offset: Int, generation current: Int) async {
        let query = query
        let service = service
        let kinds = kind.map { Set([$0]) } ?? Set(CatalogSearchKind.allCases)
        let index = kind.flatMap { kind in groups.firstIndex { $0.kind == kind } }
        if requestsAllowed(at: now()) { retryAfter = nil }
        if let index {
            groups[index].isLoading = true
            groups[index].error = nil
            groups[index].retryAfter = nil
        } else {
            isLoading = true
            error = nil
        }
        defer {
            if generation == current {
                if let index, let kind {
                    groups[index].isLoading = false
                    requests[kind] = nil
                } else {
                    isLoading = false
                    initialRequest = nil
                }
            }
        }
        let label = kind?.rawValue ?? "all"
        BopifyLog.library.debug("catalog search page loading kind=\(label, privacy: .public) offset=\(offset, privacy: .public) generation=\(current, privacy: .public)")
        do {
            let task = Task { try await service.search(query: query, kinds: kinds, offset: offset, limit: 10) }
            if let kind { requests[kind] = task } else { initialRequest = task }
            let pages = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            guard generation == current, !Task.isCancelled else { return }
            var replacement = groups
            for index in replacement.indices where kinds.contains(replacement[index].kind) {
                guard let page = pages[replacement[index].kind],
                      page.nextOffset.map({ $0 > offset && $0 <= 1000 }) ?? true else { throw LibraryError.invalidResponse }
                var items = kind == nil ? [] : replacement[index].results
                var seen = Set(items.map(\.uri))
                items.append(contentsOf: page.results.filter { seen.insert($0.uri).inserted })
                replacement[index].results = items
                replacement[index].nextOffset = page.nextOffset
            }
            groups = replacement
            if kind == nil { hasSearched = true }
            if !results.contains(where: { $0.uri == selectedURI }) { selectedURI = nil }
            if kind == nil, case .resource = SpotifySearchInput(query), results.count == 1 {
                selectedURI = results[0].uri
            }
            BopifyLog.library.debug("catalog search ready kind=\(label, privacy: .public) count=\(self.results.count, privacy: .public) generation=\(current, privacy: .public)")
        } catch is CancellationError {
        } catch {
            guard generation == current, !Task.isCancelled else { return }
            let failure = error as? LibraryError ?? .unavailable
            switch failure {
            case let .rateLimited(seconds), let .quotaExceeded(seconds):
                let deadline = now().addingTimeInterval(TimeInterval(seconds ?? 60))
                retryAfter = max(retryAfter ?? deadline, deadline)
            default: break
            }
            if let index {
                groups[index].error = failure
                groups[index].retryAfter = retryAfter
            } else {
                self.error = failure
            }
            BopifyLog.library.notice("catalog search failed kind=\(label, privacy: .public) generation=\(current, privacy: .public)")
        }
    }
}
