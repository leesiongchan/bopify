import Foundation
import Testing
import BopifyDomain
@testable import BopifyLibrary

@MainActor @Suite("Saved collection covers")
struct SavedCollectionsModelTests {
    private func collection(_ id: String, kind: LibraryCollectionKind = .playlists) -> LibraryCollection {
        LibraryCollection(uri: SpotifyURI("spotify:\(kind == .albums ? "album" : kind == .artists ? "artist" : "playlist"):\(id)")!,
                          title: id, subtitle: "Owner", artwork: nil)
    }

    @Test func coversPlayCollectionContextsAndPagingKeepsSelection() async {
        let first = collection("first"), second = collection("second"), album = collection("album", kind: .albums)
        let service = CollectionFixture(page: .init(items: [first], nextCursor: .offset(50)), albums: .init(items: [album], nextCursor: nil))
        let model = SavedCollectionsModel(service: service)
        await model.reveal(at: Date())
        #expect(model.items == [first, album])
        #expect(model.playRequest(for: first) == PlayRequest(contextURI: first.uri))
        #expect(model.playRequest(for: album) == PlayRequest(contextURI: album.uri))
        model.select(album.uri)
        await service.setPage(.init(items: [first, second], nextCursor: nil))
        await model.loadMore()
        #expect(model.items == [first, album, second] && model.selectedURI == album.uri)
        #expect(!model.hasMore)
        #expect(await service.requests == ["playlists:0:50", "albums:0:50", "artists:start:50", "playlists:50:50"])
    }

    @Test func albumsContinueAfterAnEmptyPlaylistPage() async {
        let album = collection("album", kind: .albums)
        let service = CollectionFixture(page: .init(items: [], nextCursor: nil), albums: .init(items: [], nextCursor: .offset(50)))
        let model = SavedCollectionsModel(service: service)
        await model.reveal(at: Date())
        await service.setAlbums(.success(.init(items: [album], nextCursor: nil)))
        await model.loadMore()
        #expect(model.items == [album] && !model.hasMore)
        #expect(await service.requests == ["playlists:0:50", "albums:0:50", "artists:start:50", "albums:50:50"])
    }

    @Test(arguments: [nil, 50] as [Int?])
    func retryKeepsSuccessfulCoversAndOnlyRetriesTheFailedSource(playlistNextOffset: Int?) async {
        let playlist = collection("playlist"), album = collection("album", kind: .albums)
        let service = CollectionFixture(page: .init(items: [playlist], nextCursor: playlistNextOffset.map(LibraryCollectionCursor.offset)))
        await service.setAlbums(.failure(.unavailable))
        let model = SavedCollectionsModel(service: service)
        await model.reveal(at: Date())
        #expect(model.items == [playlist] && model.error == .unavailable)
        await service.setAlbums(.success(.init(items: [album], nextCursor: nil)))
        await model.retry(at: Date())
        #expect(model.items == [playlist, album] && model.error == nil)
        #expect(model.hasMore == (playlistNextOffset != nil))
        #expect(await service.requests == ["playlists:0:50", "albums:0:50", "artists:start:50", "albums:0:50"])
    }

    @Test func playlistFailureStillShowsAlbumsAndRetryDoesNotReloadThem() async {
        let album = collection("album", kind: .albums)
        let service = CollectionFixture(page: .init(items: [], nextCursor: nil), albums: .init(items: [album], nextCursor: nil))
        await service.setPlaylistError(.forbidden)
        let model = SavedCollectionsModel(service: service)
        await model.reveal(at: Date())
        #expect(model.items == [album] && model.error == .forbidden)
        await service.setPlaylistError(nil)
        await model.retry(at: Date())
        #expect(model.items == [album] && model.error == nil && !model.hasMore)
        #expect(await service.requests == ["playlists:0:50", "albums:0:50", "artists:start:50", "playlists:0:50"])
    }

    @Test func clearRejectsLateResponse() async {
        let first = collection("first")
        let service = CollectionFixture(page: .init(items: [first], nextCursor: nil))
        let model = SavedCollectionsModel(service: service)
        await service.holdNext()
        let loading = Task { await model.reveal(at: Date()) }
        await service.waitUntilHeld()
        model.clear()
        #expect(model.items.isEmpty && !model.isLoading)
        await model.reveal(at: Date())
        await service.finishHeld(.init(items: [collection("late")], nextCursor: nil))
        await loading.value
        #expect(model.items == [first] && model.selectedURI == first.uri && !model.isLoading)
    }

    @Test func cancelledInitialLoadResumesMissingSourcesOnReveal() async {
        let playlist = collection("playlist"), album = collection("album", kind: .albums)
        let service = CollectionFixture(page: .init(items: [playlist], nextCursor: .offset(50)),
                                        albums: .init(items: [album], nextCursor: nil))
        let model = SavedCollectionsModel(service: service)
        await service.holdNext(.albums)
        let loading = Task { await model.reveal(at: Date()) }
        await service.waitUntilHeld()
        model.select(playlist.uri)
        loading.cancel()
        model.hide(at: Date())
        await service.failHeld(CancellationError())
        await loading.value
        #expect(model.items == [playlist] && !model.isLoading)

        await model.reveal(at: Date())
        #expect(model.items == [playlist, album] && model.selectedURI == playlist.uri)
        #expect(model.hasMore)
        #expect(await service.requests == ["playlists:0:50", "albums:0:50", "albums:0:50", "artists:start:50"])
    }

    @Test func newRevealKeepsTheInitialLoadFromACancelledView() async {
        let playlist = collection("playlist"), album = collection("album", kind: .albums)
        let service = CollectionFixture(page: .init(items: [playlist], nextCursor: .offset(50)),
                                        albums: .init(items: [album], nextCursor: nil))
        let model = SavedCollectionsModel(service: service)
        await service.holdNext(.albums)
        let loading = Task { await model.reveal(at: Date()) }
        await service.waitUntilHeld()
        loading.cancel()
        model.hide(at: Date())
        let reopened = await startLibraryReveal { await model.reveal(at: Date()) }
        await service.finishHeld(.init(items: [album], nextCursor: nil))
        await loading.value
        await reopened.value
        #expect(model.items == [playlist, album] && !model.isLoading && model.hasMore)
        #expect(await service.requests == ["playlists:0:50", "albums:0:50", "artists:start:50"])
    }

    @Test func artistAuthorizationFailureIsReportedAndRetryKeepsSelection() async {
        let playlist = collection("playlist"), album = collection("album", kind: .albums)
        let artist = collection("artistA", kind: .artists), nextArtist = collection("artistB", kind: .artists)
        let service = CollectionFixture(page: .init(items: [playlist], nextCursor: nil), albums: .init(items: [album], nextCursor: nil))
        await service.setArtists(.failure(.authorizationRequired))
        let model = SavedCollectionsModel(service: service)
        await model.reveal(at: Date())
        #expect(model.items == [playlist, album] && model.error == .authorizationRequired)
        await service.setArtists(.success(.init(items: [artist], nextCursor: .after("artistA"))))
        await model.retry(at: Date())
        model.select(artist.uri)
        #expect(model.items == [playlist, album, artist] && model.error == nil)
        #expect(model.playRequest(for: artist) == PlayRequest(contextURI: artist.uri))
        await service.setArtists(.success(.init(items: [artist, nextArtist], nextCursor: nil)))
        await model.loadMore()
        #expect(model.items == [playlist, album, artist, nextArtist] && model.selectedURI == artist.uri && !model.hasMore)
        #expect(await service.requests == ["playlists:0:50", "albums:0:50", "artists:start:50", "artists:start:50", "artists:artistA:50"])
    }
}

private actor CollectionFixture: LibraryCollectionsService {
    var requests: [String] = []
    private var page: LibraryCollectionsPage
    private var playlistError: LibraryError?
    private var albums: Result<LibraryCollectionsPage, LibraryError>
    private var artists: Result<LibraryCollectionsPage, LibraryError> = .success(.init(items: [], nextCursor: nil))
    private var shouldHold = false
    private var heldKind: LibraryCollectionKind?
    private var held: CheckedContinuation<LibraryCollectionsPage, Error>?
    private var started: CheckedContinuation<Void, Never>?
    init(page: LibraryCollectionsPage, albums: LibraryCollectionsPage = .init(items: [], nextCursor: nil)) {
        self.page = page
        self.albums = .success(albums)
    }
    func setPage(_ page: LibraryCollectionsPage) { self.page = page }
    func setPlaylistError(_ error: LibraryError?) { playlistError = error }
    func setAlbums(_ result: Result<LibraryCollectionsPage, LibraryError>) { albums = result }
    func setArtists(_ result: Result<LibraryCollectionsPage, LibraryError>) { artists = result }
    func holdNext(_ kind: LibraryCollectionKind? = nil) { shouldHold = true; heldKind = kind }
    func waitUntilHeld() async {
        if held != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finishHeld(_ page: LibraryCollectionsPage) { held?.resume(returning: page); held = nil }
    func failHeld(_ error: Error) { held?.resume(throwing: error); held = nil }
    func savedCollections(_ kind: LibraryCollectionKind, cursor: LibraryCollectionCursor, limit: Int) async throws -> LibraryCollectionsPage {
        let position: String = switch cursor { case .offset(let offset): String(offset); case .after(let id): id ?? "start" }
        requests.append("\(kind.rawValue):\(position):\(limit)")
        if shouldHold, heldKind == nil || heldKind == kind {
            shouldHold = false
            return try await withCheckedThrowingContinuation { held = $0; started?.resume(); started = nil }
        }
        if kind == .artists { return try artists.get() }
        if kind == .albums { return try albums.get() }
        if let playlistError { throw playlistError }
        return page
    }
}
