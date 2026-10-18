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
        #expect(await service.requests == ["song name:0:10"])
        #expect(model.tracks == [testTrack("first")])
        #expect(model.selectedURI == nil)
        #expect(model.playRequest(for: testTrack("first")) == PlayRequest(contextURI: testTrack("first").uri))
        #expect(model.playRequest(for: testTrack("other")) == nil)
    }

    @Test func cancelledDebounceNeverCallsTheService() async {
        let service = SearchFixture()
        let model = SearchModel(service: service, debounce: { throw CancellationError() })
        model.updateQuery("song")
        await model.search()
        #expect(await service.requests.isEmpty)
        #expect(!model.isLoading && model.error == nil)
    }

    @Test func resultsWaitForSelectionAndArrowKeysStartAtTheEdges() async {
        let service = SearchFixture()
        let model = SearchModel(service: service, debounce: {})
        model.updateQuery("song")
        await model.search()
        #expect(model.selectedURI == nil)
        await service.setPage(TrackSearchPage(tracks: [testTrack("second")], nextOffset: nil))
        await model.loadMore()
        #expect(model.selectedURI == nil)
        model.moveSelection(by: 1)
        #expect(model.selectedURI == testTrack("first").uri)
        model.moveSelection(by: 1)
        #expect(model.selectedURI == testTrack("second").uri)
        model.moveSelection(by: 1)
        #expect(model.selectedURI == testTrack("second").uri)
        model.updateQuery("another")
        await service.setPage(TrackSearchPage(tracks: [testTrack("first"), testTrack("second")], nextOffset: nil))
        await model.search()
        #expect(model.selectedURI == nil)
        model.moveSelection(by: -1)
        #expect(model.selectedURI == testTrack("second").uri)
        model.moveSelection(by: -1)
        model.moveSelection(by: -1)
        #expect(model.selectedURI == testTrack("first").uri)
    }

    @Test func newerQueryRejectsOldResponseEvenWhenServiceIgnoresCancellation() async {
        let service = SearchFixture()
        await service.holdNext()
        let model = SearchModel(service: service, debounce: {})
        model.updateQuery("old")
        let loading = Task { await model.search() }
        await service.waitUntilHeld()
        model.updateQuery("new")
        #expect(model.tracks.isEmpty)
        await model.search()
        await service.finishHeld(TrackSearchPage(tracks: [testTrack("old")], nextOffset: nil))
        await loading.value
        #expect(model.tracks == [testTrack("first")])
        #expect(model.query == "new" && !model.isLoading)
    }

    @Test func pagingDeduplicatesPreservesSelectionAndRejectsLatePagesAfterClear() async {
        let service = SearchFixture()
        let model = SearchModel(service: service, debounce: {})
        model.updateQuery("song")
        await model.search()
        model.select(testTrack("first").uri)
        await service.setPage(TrackSearchPage(tracks: [testTrack("first"), testTrack("second")], nextOffset: 20))
        await model.loadMore()
        #expect(model.tracks.map(\.uri) == [testTrack("first").uri, testTrack("second").uri])
        #expect(model.selectedURI == testTrack("first").uri)
        model.moveSelection(by: 1)
        #expect(model.selectedURI == testTrack("second").uri)
        await service.holdNext()
        let paging = Task { await model.loadMore() }
        await service.waitUntilHeld()
        model.clear()
        await service.finishHeld(TrackSearchPage(tracks: [testTrack("late")], nextOffset: nil))
        await paging.value
        #expect(model.tracks.isEmpty && model.query.isEmpty)
        #expect(model.selectedURI == nil && !model.isLoading && !model.hasMore)
        #expect(await service.cancelledRequests == 1)
    }

    @Test func failedNextPageKeepsResultsAndRetryUsesSameOffsetAfterCooldown() async {
        let service = SearchFixture()
        let model = SearchModel(service: service, debounce: {})
        model.updateQuery("song")
        await model.search()
        await service.fail(.rateLimited(retryAfterSeconds: 30))
        await model.loadMore()
        #expect(model.tracks == [testTrack("first")])
        #expect(model.retryAfter != nil)
        let count = await service.requests.count
        await model.retry(at: Date())
        #expect(await service.requests.count == count)
        await service.setPage(TrackSearchPage(tracks: [testTrack("second")], nextOffset: nil))
        await model.retry(at: .distantFuture)
        #expect(model.tracks.count == 2 && model.error == nil)
        #expect(await service.requests.last == "song:10:10")
    }

    @Test func cancellationKeepsTheSearchAndRejectsLateWorkUntilPagingResumes() async {
        let service = SearchFixture()
        let model = SearchModel(service: service, debounce: {})
        model.updateQuery("song")
        await model.search()
        model.select(testTrack("first").uri)
        await service.holdNext()
        let paging = Task { await model.loadMore() }
        await service.waitUntilHeld()
        model.cancel()
        #expect(model.query == "song" && model.tracks == [testTrack("first")])
        #expect(model.selectedURI == testTrack("first").uri && model.hasMore && !model.isLoading)
        await service.finishHeld(TrackSearchPage(tracks: [testTrack("late")], nextOffset: nil))
        await paging.value
        #expect(model.tracks == [testTrack("first")] && model.error == nil)
        #expect(await service.cancelledRequests == 1)
        await service.setPage(TrackSearchPage(tracks: [testTrack("second")], nextOffset: nil))
        await model.loadMore()
        #expect(model.tracks == [testTrack("first"), testTrack("second")])
        #expect(await service.requests == ["song:0:10", "song:10:10", "song:10:10"])
        model.updateQuery("")
        #expect(model.query.isEmpty && model.tracks.isEmpty && model.selectedURI == nil)
    }
}

private actor SearchFixture: TrackSearchService {
    var requests: [String] = []
    var cancelledRequests = 0
    private var page = TrackSearchPage(tracks: [testTrack("first")], nextOffset: 10)
    private var error: LibraryError?
    private var shouldHold = false
    private var held: CheckedContinuation<TrackSearchPage, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func setPage(_ value: TrackSearchPage) { page = value; error = nil }
    func fail(_ failure: LibraryError) { error = failure }
    func holdNext() { shouldHold = true }
    func waitUntilHeld() async {
        if held != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finishHeld(_ page: TrackSearchPage) { held?.resume(returning: page); held = nil }
    func searchTracks(query: String, offset: Int, limit: Int) async throws -> TrackSearchPage {
        requests.append("\(query):\(offset):\(limit)")
        if shouldHold {
            shouldHold = false
            let page = await withCheckedContinuation { held = $0; started?.resume(); started = nil }
            if Task.isCancelled { cancelledRequests += 1 }
            return page
        }
        if let error { throw error }
        return page
    }
}
