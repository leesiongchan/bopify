import Foundation
import Testing
import BopifyDomain
@testable import BopifyLibrary

@MainActor @Suite("Saved collection covers")
struct SavedCollectionsModelTests {
    private func collection(_ id: String, kind: LibraryCollectionKind = .playlists) -> LibraryCollection {
        LibraryCollection(uri: SpotifyURI("spotify:\(kind == .albums ? "album" : "playlist"):\(id)")!,
                          title: id, subtitle: "Owner", artwork: nil)
    }

    @Test func coversPlayCollectionContextsAndPagingKeepsSelection() async {
        let first = collection("first"), second = collection("second")
        let service = CollectionFixture(page: .init(items: [first], nextOffset: 50))
        let model = SavedCollectionsModel(service: service)
        await model.reveal(at: Date())
        #expect(model.items == [first])
        #expect(model.playRequest(for: first) == PlayRequest(contextURI: first.uri))
        await service.setPage(.init(items: [first, second], nextOffset: nil))
        await model.loadMore()
        #expect(model.items == [first, second] && model.selectedURI == first.uri)
        #expect(await service.requests == ["playlists:0:50", "playlists:50:50"])
    }

    @Test func kindChangeRejectsLatePlaylistAndAlbumPlaysItsOwnContext() async {
        let album = collection("album", kind: .albums)
        let service = CollectionFixture(page: .init(items: [album], nextOffset: nil))
        await service.holdNext()
        let model = SavedCollectionsModel(service: service)
        let playlists = Task { await model.reveal(at: Date()) }
        await service.waitUntilHeld()
        await model.selectKind(.albums)
        await service.finishHeld(.init(items: [collection("late")], nextOffset: nil))
        await playlists.value
        #expect(model.kind == .albums && model.items == [album])
        #expect(model.playRequest(for: album) == PlayRequest(contextURI: album.uri))
    }

    @Test func clearRejectsLateResponseAndHiddenRefreshWaitsForReveal() async {
        let service = CollectionFixture(page: .init(items: [collection("first")], nextOffset: nil))
        let model = SavedCollectionsModel(service: service)
        await model.refresh()
        #expect(await service.requests.isEmpty)
        await service.holdNext()
        let loading = Task { await model.reveal(at: Date()) }
        await service.waitUntilHeld()
        model.clear()
        await service.finishHeld(.init(items: [collection("late")], nextOffset: nil))
        await loading.value
        #expect(model.items.isEmpty && model.selectedURI == nil && !model.isLoading)
    }
}

private actor CollectionFixture: LibraryCollectionsService {
    var requests: [String] = []
    private var page: LibraryCollectionsPage
    private var shouldHold = false
    private var held: CheckedContinuation<LibraryCollectionsPage, Never>?
    private var started: CheckedContinuation<Void, Never>?
    init(page: LibraryCollectionsPage) { self.page = page }
    func setPage(_ page: LibraryCollectionsPage) { self.page = page }
    func holdNext() { shouldHold = true }
    func waitUntilHeld() async {
        if held != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finishHeld(_ page: LibraryCollectionsPage) { held?.resume(returning: page); held = nil }
    func savedCollections(_ kind: LibraryCollectionKind, offset: Int, limit: Int) async throws -> LibraryCollectionsPage {
        requests.append("\(kind.rawValue):\(offset):\(limit)")
        if shouldHold {
            shouldHold = false
            return await withCheckedContinuation { held = $0; started?.resume(); started = nil }
        }
        return page
    }
}
