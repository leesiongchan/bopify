// The injected app initializer is available only in Debug builds.
#if DEBUG
import Foundation
import Testing
import BopifyAuth
import BopifyDomain
import BopifyLibrary
import BopifyPlayback

@MainActor
@Suite("App authorization cancellation", .serialized)
struct AppEnvironmentAuthorizationTests {
    @Test func initialSignInCanBeCancelledAndRetried() async throws {
        try await withFixture { fixture in
            await fixture.environment.restoreOrPromptSignIn()
            #expect(fixture.environment.authState == .signedOut)

            for attempt in 1...2 {
                let signIn = Task { await fixture.environment.signIn() }
                try await eventually { fixture.browser.count == attempt }
                fixture.environment.cancelPlaybackAuthorization()
                try await eventually { !fixture.environment.isAuthorizingPlayback }
                await signIn.value
                #expect(fixture.environment.authState == .signedOut)
                #expect(fixture.store.load() == nil)
            }
        }
    }

    @Test func libraryCancellationPreservesSessionModelsAndGrant() async throws {
        try await withFixture { fixture in
            let selected = try #require(SpotifyURI("spotify:track:TEST123"))
            await fixture.environment.favorite.select(selected)
            let saved = fixture.libraryStore.load()
            let consent = Task { await fixture.environment.enableFavorites() }
            try await eventually { fixture.libraryBrowser.count == 1 }

            fixture.environment.cancelLibraryAuthorization()
            try await eventually { !fixture.environment.isEnablingLibrary }
            await consent.value

            #expect(fixture.environment.authState == .signedIn)
            #expect(fixture.environment.player === fixture.player)
            #expect(fixture.environment.favorite.uri == selected)
            #expect(fixture.environment.favorite.saved == true)
            #expect(fixture.environment.libraryAuthorizationNotice == nil)
            #expect(fixture.libraryStore.load() == saved)
        }
    }

    @Test func queuedSignInCancellationNeverOpensTheBrowser() async throws {
        try await withFixture { fixture in
            await fixture.environment.restoreOrPromptSignIn()
            fixture.store.armLoad()
            defer { fixture.store.loadRelease.signal() }
            let restoring = Task { await fixture.environment.restoreOrPromptSignIn() }
            try await eventually { fixture.store.blockedLoads.count == 1 }
            let signIn = Task { await fixture.environment.signIn() }
            try await eventually { fixture.environment.isAuthorizingPlayback }

            fixture.environment.cancelPlaybackAuthorization()
            fixture.store.loadRelease.signal()
            await restoring.value
            try await eventually { !fixture.environment.isAuthorizingPlayback }
            await signIn.value

            #expect(fixture.browser.count == 0)
            #expect(fixture.environment.authState == .signedOut)
        }
    }

    @Test func signOutCancelsPendingConsentAndClearsInjectedStores() async throws {
        try await withFixture { fixture in
            await fixture.environment.restoreOrPromptSignIn()
            let signIn = Task { await fixture.environment.signIn() }
            try await eventually { fixture.browser.count == 1 }

            await fixture.environment.signOut()
            await signIn.value

            #expect(fixture.environment.authState == .signedOut)
            #expect(!fixture.environment.isAuthorizingPlayback)
            #expect(fixture.environment.player == nil)
            #expect(fixture.store.load() == nil)
            #expect(fixture.libraryStore.load() == nil)
        }
    }

    @Test func quittingCancelsBothConsentsWithoutDeletingSavedGrants() async throws {
        try await withFixture { fixture in
            let saved = TokenSet(accessToken: "PLAYBACK", refreshToken: "REFRESH",
                expiresAt: .distantFuture, grantedScopes: ["streaming"])
            fixture.store.save(saved)
            let libraryGrant = fixture.libraryStore.load()
            let library = Task { await fixture.environment.enableFavorites() }
            try await eventually { fixture.libraryBrowser.count == 1 }
            let playback = Task { await fixture.environment.signIn() }
            try await eventually { fixture.browser.count == 1 }

            await fixture.environment.prepareForQuit()
            await playback.value
            await library.value

            #expect(!fixture.environment.isAuthorizingPlayback)
            #expect(!fixture.environment.isEnablingLibrary)
            #expect(fixture.environment.player == nil)
            #expect(fixture.store.load() == saved)
            #expect(fixture.libraryStore.load() == libraryGrant)
        }
    }
}

@MainActor
private func eventually(_ predicate: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !predicate(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(predicate(), "Authorization state did not settle before the deadline")
}

@MainActor
private func withFixture(_ body: @MainActor (AuthorizationFixture) async throws -> Void) async throws {
    let fixture = AuthorizationFixture()
    do { try await body(fixture) }
    catch {
        await fixture.stop()
        throw error
    }
    await fixture.stop()
}

@MainActor
private struct AuthorizationFixture {
    let store = AuthorizationStore()
    let libraryStore: AuthorizationStore
    let browser = AuthorizationCounter()
    let libraryBrowser = AuthorizationCounter()
    let player = PlayerModel()
    let environment: AppEnvironment
    private let playbackAuth: SpotifyAuthService
    private let libraryAuth: SpotifyAuthService

    init() {
        libraryStore = AuthorizationStore(TokenSet(accessToken: "LIBRARY", refreshToken: "REFRESH",
            expiresAt: .distantFuture, grantedScopes: ["user-library-read"]))
        let playback = SpotifyAuthService(clientID: "test", store: store,
            openURL: { [browser] _ in browser.increment() })
        let library = SpotifyAuthService(clientID: "test-library", store: libraryStore,
            openURL: { [libraryBrowser] _ in libraryBrowser.increment() })
        playbackAuth = playback
        libraryAuth = library
        environment = AppEnvironment(previewPlayer: player, favoriteService: AuthorizationLibrary(),
            authorizeLibraryScopes: { scopes in _ = try await library.authorizeLibraryScopes(scopes) },
            playbackAuth: playback, libraryAuth: library)
    }

    func stop() async {
        store.loadRelease.signal()
        await playbackAuth.cancelPendingWork()
        await libraryAuth.cancelPendingWork()
        await environment.prepareForQuit()
    }
}

private nonisolated final class AuthorizationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

private nonisolated final class AuthorizationStore: TokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: TokenSet?
    private var holdNextLoad = false
    let blockedLoads = AuthorizationCounter()
    let loadRelease = DispatchSemaphore(value: 0)

    init(_ tokens: TokenSet? = nil) { self.tokens = tokens }
    func save(_ tokens: TokenSet) { lock.withLock { self.tokens = tokens } }
    func clear() { lock.withLock { tokens = nil } }
    func armLoad() { lock.withLock { holdNextLoad = true } }
    func load() -> TokenSet? {
        let hold = lock.withLock {
            let value = holdNextLoad
            holdNextLoad = false
            return value
        }
        if hold {
            blockedLoads.increment()
            loadRelease.wait()
        }
        return lock.withLock { tokens }
    }
}

private struct AuthorizationLibrary: LibraryService {
    func savedState(for uri: SpotifyURI) async throws -> Bool { true }
    func save(_ uri: SpotifyURI) async throws {}
    func remove(_ uri: SpotifyURI) async throws {}
}
#endif
