import Foundation
import Testing
import BopifyDomain
@testable import BopifyLibrary

@MainActor @Suite("Catalog search")
struct SearchModelTests {
    @Test func normalizesQueriesAndSkipsBlankRequests() async {
        let service = SearchFixture()
        let model = SearchModel(service: service, debounce: {})
        model.updateQuery(" \n ")
        await model.search()
        #expect(await service.requests.isEmpty)
        model.updateQuery("  song name  ")
        await model.search()
        #expect(await service.requests == [SearchRequest(query: "song name", kinds: [.song, .album, .artist, .playlist], offset: 0, limit: 2)])
        #expect(model.query == "song name" && model.selectedURI == nil)
        #expect(model.results.first == .song(testTrack("first")))
    }

    @Test func cancelledDebounceNeverCallsTheService() async {
        let service = SearchFixture()
        let model = SearchModel(service: service, debounce: { throw CancellationError() })
        model.updateQuery("song")
        await model.search()
        #expect(await service.requests.isEmpty)
        #expect(!model.isLoading && model.error == nil && !model.hasSearched)
    }

    @Test func initialSearchRequestsTwoPerKindAndPreservesGroupOrder() async {
        let service = SearchFixture()
        let model = SearchModel(service: service, debounce: {})
        model.updateQuery("music")
        await model.search()
        #expect(model.groups.map(\.kind) == [.song, .album, .artist, .playlist])
        #expect(model.results.map(\.kind) == [.song, .album, .artist, .playlist])
        #expect(model.hasSearched && !model.isLoading && model.error == nil)
        #expect(model.selectedURI == nil)
        #expect(await service.requests == [SearchRequest(query: "music", kinds: [.song, .album, .artist, .playlist], offset: 0, limit: 2)])
        for kind in CatalogSearchKind.allCases {
            await service.setPage(CatalogSearchPage(results: [], nextOffset: nil), for: kind)
        }
        model.updateQuery("empty")
        await model.search()
        #expect(model.results.isEmpty && model.hasSearched)
        model.cancel()
        await model.search()
        #expect(await service.requests.count == 2)
    }

    @Test func moreRequestsOnlyOneGroupAndPreservesLaterSelection() async {
        let service = SearchFixture()
        let model = SearchModel(service: service, debounce: {})
        model.updateQuery("music")
        await model.search()
        model.select(searchResult(.playlist, "first").uri)
        let others = model.groups.filter { $0.kind != .song }
        await service.holdNext([.song])
        let loading = Task { await model.loadMore(.song) }
        await service.waitUntilHeld([.song])
        #expect(searchGroup(model, .song).isLoading && !model.isLoading)
        await model.loadMore(.song)
        #expect(await service.requests.count == 2)
        await service.finishHeld([.song: CatalogSearchPage(results: [searchResult(.song, "second")], nextOffset: nil)], kinds: [.song])
        await loading.value
        #expect(model.groups.filter { $0.kind != .song } == others)
        #expect(model.selectedURI == SpotifyURI("spotify:playlist:first"))
        #expect(searchGroup(model, .song).results.map(\.uri.rawValue) == ["spotify:track:first", "spotify:track:second"])
        #expect(await service.requests.last == SearchRequest(query: "music", kinds: [.song], offset: 2, limit: 10))
    }

    @Test func groupsCompleteIndependentlyAndDeduplicate() async {
        let service = SearchFixture()
        let model = SearchModel(service: service, debounce: {})
        model.updateQuery("music")
        await model.search()
        await service.holdNext([.album])
        await service.holdNext([.playlist])
        let album = Task { await model.loadMore(.album) }
        let playlist = Task { await model.loadMore(.playlist) }
        await service.waitUntilHeld([.album])
        await service.waitUntilHeld([.playlist])
        await service.finishHeld([.playlist: CatalogSearchPage(results: [searchResult(.playlist, "second")], nextOffset: nil)], kinds: [.playlist])
        await playlist.value
        #expect(searchGroup(model, .album).isLoading)
        #expect(searchGroup(model, .playlist).results.count == 2)
        await service.finishHeld([.album: CatalogSearchPage(results: [searchResult(.album, "first"), searchResult(.album, "second")], nextOffset: 12)], kinds: [.album])
        await album.value
        #expect(searchGroup(model, .album).results.map(\.uri.rawValue) == ["spotify:album:first", "spotify:album:second"])
        #expect(searchGroup(model, .album).nextOffset == 12)
        #expect(searchGroup(model, .playlist).nextOffset == nil)
    }

    @Test func newerQueryRejectsOldResponseEvenWhenServiceIgnoresCancellation() async {
        let service = SearchFixture()
        await service.holdNext()
        let model = SearchModel(service: service, debounce: {})
        model.updateQuery("old")
        let loading = Task { await model.search() }
        await service.waitUntilHeld()
        model.updateQuery("new")
        #expect(model.results.isEmpty)
        await model.search()
        let current = model.groups
        await service.finishHeld([.song: CatalogSearchPage(results: [searchResult(.song, "old")], nextOffset: nil)])
        await loading.value
        #expect(model.groups == current && model.query == "new")
        #expect(!model.isLoading && model.error == nil)
        #expect(await service.cancelledRequests == 1)
    }

    @Test(arguments: ["query", "clear", "cancel"])
    func newQueryClearAndCancelRejectEveryLateGroupReply(_ action: String) async {
        let service = SearchFixture()
        let model = SearchModel(service: service, debounce: {})
        model.updateQuery("music")
        await model.search()
        model.select(searchResult(.playlist, "first").uri)
        await service.holdNext([.album])
        await service.holdNext([.playlist])
        let album = Task { await model.loadMore(.album) }
        let playlist = Task { await model.loadMore(.playlist) }
        await service.waitUntilHeld([.album])
        await service.waitUntilHeld([.playlist])
        switch action {
        case "query": model.updateQuery("new"); await model.search()
        case "clear": model.clear()
        default: model.cancel()
        }
        let groups = model.groups
        let selected = model.selectedURI
        await service.finishHeld([.album: CatalogSearchPage(results: [searchResult(.album, "late")], nextOffset: nil)], kinds: [.album])
        await service.failHeld(.unavailable, kinds: [.playlist])
        await album.value
        await playlist.value
        #expect(model.groups == groups && model.selectedURI == selected)
        #expect(!model.isLoading && model.error == nil)
        #expect(await service.cancelledRequests == 2)
    }

    @Test func closeAndReopenRetainCompletedAndInterruptedState() async {
        let service = SearchFixture()
        let model = SearchModel(service: service, debounce: {})
        model.updateQuery("music")
        await service.holdNext()
        let initial = Task { await model.search() }
        await service.waitUntilHeld()
        model.cancel()
        await service.finishHeld([:])
        await initial.value
        #expect(!model.hasSearched && !model.isLoading)
        await model.search()
        model.select(searchResult(.song, "first").uri)
        let completed = model.groups
        await service.holdNext([.song])
        let page = Task { await model.loadMore(.song) }
        await service.waitUntilHeld([.song])
        model.cancel()
        #expect(model.groups == completed && model.query == "music")
        await service.finishHeld([.song: CatalogSearchPage(results: [searchResult(.song, "late")], nextOffset: nil)], kinds: [.song])
        await page.value
        #expect(model.groups == completed && model.hasSearched)
        #expect(model.selectedURI == SpotifyURI("spotify:track:first"))
        await model.search()
        #expect(await service.requests.count == 3)
        await service.setPage(CatalogSearchPage(results: [searchResult(.song, "second")], nextOffset: nil), for: .song)
        await model.loadMore(.song)
        #expect(searchGroup(model, .song).results.count == 2)
        #expect(await service.requests.last?.offset == 2)
    }

    @Test func groupFailureRetriesItsOffsetAndPreservesOtherGroups() async {
        let service = SearchFixture()
        let model = SearchModel(service: service, debounce: {})
        model.updateQuery("music")
        await service.fail(.unavailable, for: .song)
        await model.search()
        #expect(model.error == .unavailable && !model.hasSearched)
        await service.setPage(CatalogSearchPage(results: [searchResult(.song, "first")], nextOffset: 2), for: .song)
        await model.retry(at: Date())
        #expect(model.hasSearched && model.error == nil)
        let original = model.results
        await service.fail(.unavailable, for: .album)
        await model.loadMore(.album)
        #expect(model.results == original && model.error == nil)
        #expect(searchGroup(model, .album).error == .unavailable)
        #expect(model.playRequest(for: searchResult(.playlist, "first")) != nil)
        await service.setPage(CatalogSearchPage(results: [searchResult(.album, "second")], nextOffset: nil), for: .album)
        await model.retry(.album, at: Date())
        #expect(searchGroup(model, .album).error == nil)
        #expect(searchGroup(model, .album).results.count == 2)
        #expect(await service.requests.last == SearchRequest(query: "music", kinds: [.album], offset: 2, limit: 10))
    }

    @Test func sharedCooldownKeepsOriginalDeadlineAcrossGroupFailures() async {
        let service = SearchFixture()
        let clock = SearchClock()
        let model = SearchModel(service: service, debounce: {}, now: { clock.now() })
        model.updateQuery("music")
        await model.search()
        await service.holdNext([.song])
        await service.holdNext([.album])
        let song = Task { await model.loadMore(.song) }
        let album = Task { await model.loadMore(.album) }
        await service.waitUntilHeld([.song])
        await service.waitUntilHeld([.album])
        await service.failHeld(.rateLimited(retryAfterSeconds: 12), kinds: [.song])
        await song.value
        #expect(model.retryAfter == Date(timeIntervalSince1970: 1012))
        clock.advance(11)
        await service.failHeld(.rateLimited(retryAfterSeconds: 1), kinds: [.album])
        await album.value
        #expect(model.retryAfter == Date(timeIntervalSince1970: 1012))
        #expect(searchGroup(model, .song).retryAfter == searchGroup(model, .album).retryAfter)
        await model.retry(.song, at: clock.now())
        await model.loadMore(.playlist)
        #expect(await service.requests.count == 3)
        clock.advance(1)
        await service.setPage(CatalogSearchPage(results: [searchResult(.song, "second")], nextOffset: nil), for: .song)
        await model.retry(.song, at: clock.now())
        #expect(searchGroup(model, .song).error == nil && searchGroup(model, .song).results.count == 2)
        #expect(await service.requests.count == 4)
    }

    @Test func selectionAndPlaybackWorkAcrossAllKinds() async {
        let service = SearchFixture()
        let model = SearchModel(service: service, debounce: {})
        model.updateQuery("music")
        await model.search()
        #expect(model.selectedURI == nil)
        model.moveSelection(by: -1)
        #expect(model.selectedURI == SpotifyURI("spotify:playlist:first"))
        model.moveSelection(by: 1)
        #expect(model.selectedURI == SpotifyURI("spotify:playlist:first"))
        for _ in 0..<5 { model.moveSelection(by: -1) }
        #expect(model.selectedURI == SpotifyURI("spotify:track:first"))
        for kind in CatalogSearchKind.allCases {
            let result = searchResult(kind, "first")
            #expect(model.selectedURI == result.uri)
            #expect(model.playRequest(for: result) == PlayRequest(contextURI: result.uri))
            #expect(model.playRequest(for: searchResult(kind, "absent")) == nil)
            model.moveSelection(by: 1)
        }
        model.clear()
        #expect(model.results.isEmpty && model.query.isEmpty && model.selectedURI == nil)
        #expect(model.groups.allSatisfy { !$0.hasMore && !$0.isLoading })
    }
}

private struct SearchRequest: Equatable, Sendable {
    let query: String
    let kinds: Set<CatalogSearchKind>
    let offset: Int
    let limit: Int
}

private actor SearchFixture: CatalogSearchService {
    var requests: [SearchRequest] = []
    var cancelledRequests = 0
    private var pages = Dictionary(uniqueKeysWithValues: CatalogSearchKind.allCases.map {
        ($0, CatalogSearchPage(results: [searchResult($0, "first")], nextOffset: 2))
    })
    private var failures: [CatalogSearchKind: LibraryError] = [:]
    private var holds: Set<Set<CatalogSearchKind>> = []
    private var held: [Set<CatalogSearchKind>: CheckedContinuation<[CatalogSearchKind: CatalogSearchPage], Error>] = [:]
    private var started: [Set<CatalogSearchKind>: CheckedContinuation<Void, Never>] = [:]

    func setPage(_ page: CatalogSearchPage, for kind: CatalogSearchKind) { pages[kind] = page; failures[kind] = nil }
    func fail(_ error: LibraryError, for kind: CatalogSearchKind) { failures[kind] = error }
    func holdNext(_ kinds: Set<CatalogSearchKind> = Set(CatalogSearchKind.allCases)) { holds.insert(kinds) }
    func waitUntilHeld(_ kinds: Set<CatalogSearchKind> = Set(CatalogSearchKind.allCases)) async {
        if held[kinds] != nil { return }
        await withCheckedContinuation { started[kinds] = $0 }
    }
    func finishHeld(_ pages: [CatalogSearchKind: CatalogSearchPage], kinds: Set<CatalogSearchKind> = Set(CatalogSearchKind.allCases)) {
        held.removeValue(forKey: kinds)?.resume(returning: pages)
    }
    func failHeld(_ error: LibraryError, kinds: Set<CatalogSearchKind>) { held.removeValue(forKey: kinds)?.resume(throwing: error) }
    func search(query: String, kinds: Set<CatalogSearchKind>, offset: Int, limit: Int) async throws -> [CatalogSearchKind: CatalogSearchPage] {
        requests.append(SearchRequest(query: query, kinds: kinds, offset: offset, limit: limit))
        if holds.remove(kinds) != nil {
            defer { if Task.isCancelled { cancelledRequests += 1 } }
            return try await withCheckedThrowingContinuation { held[kinds] = $0; started.removeValue(forKey: kinds)?.resume() }
        }
        for kind in CatalogSearchKind.allCases where kinds.contains(kind) {
            if let failure = failures[kind] { throw failure }
        }
        return pages.filter { kinds.contains($0.key) }
    }
}

private func searchResult(_ kind: CatalogSearchKind, _ id: String) -> CatalogSearchResult {
    let collection = LibraryCollection(uri: SpotifyURI("spotify:\(kind.rawValue):\(id)")!, title: "Music \(id)",
        subtitle: kind == .artist ? "" : "Artist", artwork: nil)
    return switch kind {
    case .song: .song(testTrack(id))
    case .album: .album(collection)
    case .artist: .artist(collection)
    case .playlist: .playlist(collection)
    }
}

@MainActor private func searchGroup(_ model: SearchModel, _ kind: CatalogSearchKind) -> CatalogSearchGroup {
    model.groups.first { $0.kind == kind }!
}

private final class SearchClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1000)
    func now() -> Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
}
