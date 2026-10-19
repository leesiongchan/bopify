import Foundation
import Testing
import BopifyDomain
@testable import BopifyLibrary

private actor ControlledSavedTracks: SavedTracksService {
    struct Request: Equatable { let offset: Int; let limit: Int }
    private var completion: CheckedContinuation<SavedTracksPage, Error>?
    private var requests: [Request] = []
    private var waiter: CheckedContinuation<Request, Never>?
    private(set) var count = 0
    private(set) var maxConcurrent = 0
    private var active = 0
    private var cancelled = false
    private var cancellationWaiter: CheckedContinuation<Void, Never>?
    func waitForCancellation() async {
        if cancelled { return }
        await withCheckedContinuation { cancellationWaiter = $0 }
    }
    private func didCancel() {
        cancelled = true
        cancellationWaiter?.resume()
        cancellationWaiter = nil
    }
    func savedTracks(offset: Int, limit: Int) async throws -> SavedTracksPage {
        active += 1
        maxConcurrent = max(maxConcurrent, active)
        defer { active -= 1 }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
            completion = continuation
            count += 1
            let request = Request(offset: offset, limit: limit)
            if let waiter { self.waiter = nil; waiter.resume(returning: request) }
            else { requests.append(request) }
            }
        } onCancel: { Task { await self.didCancel() } }
    }
    func next() async -> Request {
        if !requests.isEmpty { return requests.removeFirst() }
        return await withCheckedContinuation { waiter = $0 }
    }
    func resolve(_ result: Result<SavedTracksPage, Error>) {
        let current = completion
        completion = nil
        current?.resume(with: result)
    }
}

private actor PagedSavedTracks: SavedTracksService {
    private let pages: [Int: SavedTracksPage]
    private(set) var offsets: [Int] = []
    init(_ pages: [Int: SavedTracksPage]) { self.pages = pages }

    func savedTracks(offset: Int, limit: Int) async throws -> SavedTracksPage {
        offsets.append(offset)
        return pages[offset] ?? SavedTracksPage(tracks: [], nextOffset: nil, total: 0)
    }
}

@Suite("LikedSongsModel") @MainActor
struct LikedSongsModelTests {
    private let now = Date(timeIntervalSince1970: 1000)
    private func track(_ id: Int) -> Track {
        Track(uri: SpotifyURI("spotify:track:t\(id)")!, title: "Song \(id)", artists: [],
              albumTitle: nil, artwork: nil, durationMs: 100_000)
    }
    private func page(_ ids: [Int], next: Int? = nil) -> SavedTracksPage {
        SavedTracksPage(tracks: ids.map(track), nextOffset: next, total: 200)
    }
    @Test func revealPaginationDeduplicationAndHide() async {
        let service = ControlledSavedTracks()
        let model = LikedSongsModel(service: service)
        let first = Task { await model.reveal(at: now) }
        #expect(await service.next() == .init(offset: 0, limit: 50))
        await model.reveal(at: now)
        await service.resolve(.success(page(Array(0..<50), next: 50)))
        await first.value
        #expect(model.selectedURI == track(0).uri)
        await model.loadMoreIfNeeded(near: track(10).uri)
        let more = Task { await model.loadMoreIfNeeded(near: track(49).uri) }
        #expect(await service.next().offset == 50)
        await model.loadMoreIfNeeded(near: track(49).uri)
        await service.resolve(.success(page([49, 50, 51], next: 100)))
        await more.value
        #expect(model.tracks.map(\.uri) == (0...51).map { track($0).uri })
        model.hide(at: now)
        model.hide(at: now)
        await model.loadMoreIfNeeded(near: track(51).uri)
        #expect(await service.count == 2)
        #expect(await service.maxConcurrent == 1)
    }
    /// A quick tab round trip can hide the old view after the new one revealed; paging must keep working.
    @Test func staysShownWhileAnyRevealIsUnmatched() async {
        let service = PagedSavedTracks([0: page([1, 2], next: 50), 50: page([3])])
        let model = LikedSongsModel(service: service)
        await model.reveal(at: now)
        await model.reveal(at: now)
        model.hide(at: now)
        await model.loadMoreIfNeeded(near: track(2).uri)
        #expect(await service.offsets == [0, 50])
        #expect(model.tracks == [track(1), track(2), track(3)])
    }
    @Test func clearWhileShownStillRefreshes() async {
        let service = PagedSavedTracks([0: page([1])])
        let model = LikedSongsModel(service: service)
        await model.reveal(at: now)
        model.clear()
        await model.refresh()
        #expect(await service.offsets == [0, 0])
        #expect(model.tracks == [track(1)])
    }
    @Test(arguments: [true, false]) func refreshPreservesDeepSelection(stillPresent: Bool) async {
        let service = ControlledSavedTracks()
        let model = LikedSongsModel(service: service)
        let first = Task { await model.reveal(at: now) }
        _ = await service.next()
        await service.resolve(.success(page(Array(0..<50), next: 50)))
        await first.value
        for offset in [50, 100] {
            let more = Task { await model.loadMoreIfNeeded(near: track(offset - 1).uri) }
            #expect(await service.next().offset == offset)
            await service.resolve(.success(page(Array(offset..<(offset + 50)), next: offset + 50)))
            await more.value
        }
        model.select(track(125).uri)
        let refresh = Task { await model.refresh() }
        for offset in [0, 50, 100] {
            #expect(await service.next().offset == offset)
            #expect(model.tracks.first?.uri == track(0).uri)
            var ids = Array(offset..<(offset + 50))
            if offset == 0 { ids[0] = 199 }
            if !stillPresent && offset == 100 { ids[25] = 198 }
            await service.resolve(.success(page(ids, next: offset + 50)))
        }
        await refresh.value
        #expect(model.selectedURI == track(stillPresent ? 125 : 198).uri)
        #expect(model.tracks.first?.uri == track(199).uri)
        #expect(await service.count == 6)
        #expect(await service.maxConcurrent == 1)
    }
    @Test func hiddenRefreshThresholdAndFailureRetention() async {
        let service = ControlledSavedTracks()
        let model = LikedSongsModel(service: service)
        let initial = Task { await model.reveal(at: now) }
        _ = await service.next()
        await service.resolve(.success(page([1, 2])))
        await initial.value
        model.hide(at: now)
        await model.reveal(at: now.addingTimeInterval(59))
        #expect(await service.count == 1)
        model.hide(at: now.addingTimeInterval(59))
        let refresh = Task { await model.reveal(at: now.addingTimeInterval(119)) }
        _ = await service.next()
        await service.resolve(.failure(LibraryError.unavailable))
        await refresh.value
        #expect(model.tracks == [track(1), track(2)])
        #expect(model.error == .unavailable && !model.isLoading)
    }
    @Test func errorRetryDeadlineAndEmptyState() async {
        let service = ControlledSavedTracks()
        let model = LikedSongsModel(service: service, now: { now })
        let initial = Task { await model.reveal(at: now) }
        _ = await service.next()
        await service.resolve(.failure(LibraryError.rateLimited(retryAfterSeconds: 12)))
        await initial.value
        #expect(model.retryAfter == now.addingTimeInterval(12))
        await model.retry(at: now.addingTimeInterval(11))
        #expect(await service.count == 1)
        let retry = Task { await model.retry(at: now.addingTimeInterval(12)) }
        _ = await service.next()
        await service.resolve(.failure(LibraryError.authorizationRequired))
        await retry.value
        #expect(model.error == .authorizationRequired)
        model.clear()
        let reloaded = Task { await model.reveal(at: now.addingTimeInterval(12)) }
        _ = await service.next()
        await service.resolve(.success(page([])))
        await reloaded.value
        #expect(model.tracks.isEmpty && model.selectedURI == nil && model.error == nil)
        await model.reveal(at: now.addingTimeInterval(13))
        #expect(await service.count == 3)
    }
    @Test func quotaErrorRetainsDistinctReasonAndCooldown() async throws {
        let service = ControlledSavedTracks()
        let model = LikedSongsModel(service: service, now: { now })
        let initial = Task { await model.reveal(at: now) }
        _ = await service.next()
        await service.resolve(.failure(LibraryError.quotaExceeded(retryAfterSeconds: 120)))
        await initial.value
        #expect(model.error == .quotaExceeded(retryAfterSeconds: 120))
        let deadline = try #require(model.retryAfter)
        #expect(deadline == now.addingTimeInterval(120))
        await model.retry(at: now.addingTimeInterval(119))
        #expect(await service.count == 1)
    }
    @Test func refreshInvalidatesSuspendedPageAndClearRejectsLateResults() async {
        let service = ControlledSavedTracks()
        let model = LikedSongsModel(service: service)
        let old = Task { await model.reveal(at: now) }
        _ = await service.next()
        let refresh = Task { await model.refresh() }
        await service.waitForCancellation()
        await service.resolve(.success(page([1], next: 50)))
        #expect(await service.next().offset == 0)
        #expect(model.tracks.isEmpty)
        await service.resolve(.success(page([2])))
        await refresh.value
        await old.value
        #expect(model.tracks == [track(2)])
        let late = Task { await model.refresh() }
        _ = await service.next()
        model.clear()
        await service.resolve(.success(page([3])))
        await late.value
        #expect(model.tracks.isEmpty && model.selectedURI == nil && !model.isLoading)
        #expect(await service.maxConcurrent == 1)
    }
    @Test func failedNextPageRetriesSameOffsetAndRetainsSelection() async {
        let service = ControlledSavedTracks()
        let model = LikedSongsModel(service: service)
        let initial = Task { await model.reveal(at: now) }
        _ = await service.next()
        await service.resolve(.success(page([1, 2], next: 50)))
        await initial.value
        model.select(track(2).uri)
        let more = Task { await model.loadMoreIfNeeded(near: track(2).uri) }
        #expect(await service.next().offset == 50)
        await service.resolve(.failure(LibraryError.unavailable))
        await more.value
        #expect(model.tracks == [track(1), track(2)] && model.selectedURI == track(2).uri)
        let retry = Task { await model.retry(at: now) }
        #expect(await service.next().offset == 50)
        await service.resolve(.success(page([3])))
        await retry.value
        #expect(model.tracks == [track(1), track(2), track(3)] && model.error == nil)
    }

    @Test func hidingDuringRefreshRetainsDeepSelectionUntilNextReveal() async {
        let service = ControlledSavedTracks()
        let model = LikedSongsModel(service: service)
        let initial = Task { await model.reveal(at: now) }
        _ = await service.next()
        await service.resolve(.success(page(Array(0..<50), next: 50)))
        await initial.value
        let more = Task { await model.loadMoreIfNeeded(near: track(49).uri) }
        _ = await service.next()
        await service.resolve(.success(page(Array(50..<100), next: 100)))
        await more.value
        model.select(track(75).uri)
        let refresh = Task { await model.refresh() }
        _ = await service.next()
        model.hide(at: now)
        await service.resolve(.success(page(Array(0..<50), next: 50)))
        await refresh.value
        #expect(model.tracks.count == 100 && model.selectedURI == track(75).uri)
        #expect(await service.count == 3)
        guard model.tracks.count == 100 else { return }
        let reveal = Task { await model.reveal(at: now.addingTimeInterval(1)) }
        #expect(await service.next().offset == 0)
        await service.resolve(.success(page(Array(0..<50), next: 50)))
        #expect(await service.next().offset == 50)
        await service.resolve(.success(page(Array(50..<100), next: 100)))
        await reveal.value
        #expect(model.selectedURI == track(75).uri)
    }
    @Test func skippedFirstPageDoesNotHideLaterPlayableSongs() async {
        let service = ControlledSavedTracks()
        let model = LikedSongsModel(service: service)
        let initial = Task { await model.reveal(at: now) }
        _ = await service.next()
        await service.resolve(.success(page([], next: 50)))
        await initial.value
        #expect(model.hasMore && model.tracks.isEmpty)
        let more = Task { await model.loadMore() }
        #expect(await service.next().offset == 50)
        await service.resolve(.success(page([51])))
        await more.value
        #expect(model.tracks == [track(51)] && model.selectedURI == track(51).uri)
    }

    @Test func rateLimitStartsWhenFailureArrives() async {
        let service = ControlledSavedTracks()
        var clock = now
        let model = LikedSongsModel(service: service, now: { clock })
        let initial = Task { await model.reveal(at: now) }
        _ = await service.next()
        clock = now.addingTimeInterval(10)
        await service.resolve(.failure(LibraryError.rateLimited(retryAfterSeconds: 12)))
        await initial.value
        #expect(model.retryAfter == now.addingTimeInterval(22))
        guard model.retryAfter == now.addingTimeInterval(22) else { return }
        await model.retry(at: now.addingTimeInterval(21))
        #expect(await service.count == 1)
    }
}
