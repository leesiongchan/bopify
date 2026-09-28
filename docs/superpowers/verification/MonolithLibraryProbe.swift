import Foundation
import BopifyLibrary
import BopifyDomain
import BopifyPlayback
import BopifyAuth

@main struct MonolithLibraryProbe {
    actor Library: LibraryService, SavedTracksService {
        var scopes: Set<String> = []
        var requested: [Set<String>] = []
        var consent: CheckedContinuation<Void, Never>?
        var signal: CheckedContinuation<Void, Never>?
        func savedTracks(offset: Int, limit: Int) async throws -> SavedTracksPage {
            guard scopes.contains("user-library-read") else { throw LibraryError.authorizationRequired }
            return SavedTracksPage(tracks: [], nextOffset: nil, total: 0)
        }
        func savedState(for uri: SpotifyURI) async throws -> Bool {
            guard scopes.contains("user-library-read") else { throw LibraryError.authorizationRequired }
            return false
        }
        func save(_ uri: SpotifyURI) async throws {
            guard scopes.contains("user-library-modify") else { throw LibraryError.authorizationRequired }
        }
        func remove(_ uri: SpotifyURI) async throws { try await save(uri) }
        func authorize(_ required: Set<String>) async {
            requested.append(required)
            await withCheckedContinuation { continuation in
                consent = continuation
                signal?.resume(); signal = nil
            }
            scopes.formUnion(required)
        }
        func waitForConsent() async {
            if consent != nil { return }
            await withCheckedContinuation { signal = $0 }
        }
        func finishConsent() { consent?.resume(); consent = nil }
    }
    @MainActor static func main() async {
        let library = Library()
        let engine = StubPlaybackEngine()
        let player = PlayerModel(engine: engine)
        player.start()
        let environment = AppEnvironment(previewPlayer: player, favoriteService: library,
                                         savedTracksService: library, authorizeLibraryScopes: library.authorize)
        await environment.likedSongs.reveal(at: Date())
        precondition(environment.likedSongs.error == .authorizationRequired)
        let initial = await library.requested
        precondition(initial.isEmpty, "hover must not start OAuth")
        let enable = Task { await environment.enableLikedSongs() }
        await library.waitForConsent()
        await environment.enableFavorites()
        let requests = await library.requested
        precondition(requests == [["user-library-read"]], "consent actions share a guard")
        await library.finishConsent()
        await enable.value
        precondition(environment.likedSongs.error == nil)
        let uri = SpotifyURI("spotify:track:first")!
        await environment.favorite.select(uri)
        await environment.favorite.toggle()
        precondition(environment.favorite.error == .authorizationRequired, "read grant must not bypass write consent")
        let write = Task { await environment.enableFavorites() }
        await library.waitForConsent()
        let writes = await library.requested
        precondition(writes.last == ["user-library-read", "user-library-modify"])
        await library.finishConsent()
        await write.value
        precondition(engine.recordedCommands.isEmpty, "consent and browsing cannot start playback")
        await environment.prepareForQuit()
        precondition(environment.likedSongs.tracks.isEmpty && !environment.likedSongs.isLoading)
        let suffix = UUID().uuidString
        let playbackStore = KeychainTokenStore(service: "my.bopify.probe.\(suffix)")
        let libraryStore = KeychainTokenStore(service: "my.bopify.probe.\(suffix).library")
        let token = TokenSet(accessToken: "FAKE", refreshToken: "FAKE", expiresAt: Date().addingTimeInterval(3600), grantedScopes: ["streaming"])
        try! playbackStore.save(token)
        try! libraryStore.save(TokenSet(accessToken: "LIBRARY_FAKE", refreshToken: "FAKE", expiresAt: token.expiresAt, grantedScopes: ["user-library-read"]))
        let signingOut = AppEnvironment(previewPlayer: player, favoriteService: library,
                                        savedTracksService: library, authorizeLibraryScopes: library.authorize,
                                        playbackAuth: SpotifyAuthService(clientID: librespotClientID, store: playbackStore),
                                        libraryAuth: SpotifyAuthService(clientID: "dashboard", store: libraryStore))
        await signingOut.prepareForQuit()
        precondition(playbackStore.load() == token && libraryStore.load()?.accessToken == "LIBRARY_FAKE",
                     "quit preserves both grants")
        let pendingConsent = Task { await signingOut.enableLikedSongs() }
        await library.waitForConsent()
        await signingOut.signOut()
        await library.finishConsent()
        await pendingConsent.value
        precondition(playbackStore.load() == nil && libraryStore.load() == nil, "sign-out clears both grants")
        precondition(signingOut.authState == .signedOut && signingOut.likedSongs.tracks.isEmpty,
                     "late consent cannot restore browsing")
        let absent = AppEnvironment(previewPlayer: player, favoriteService: library)
        await absent.likedSongs.reveal(at: Date())
        precondition(absent.likedSongs.error == .unavailable)
        await absent.enableLikedSongs()
        precondition(absent.libraryAuthorizationNotice != nil)
        print("PASS: read consent, shared consent guard, write recovery, no playback, teardown, dual-store sign-out, late consent, fixture isolation")
    }
}
