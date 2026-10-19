#if DEBUG
import Foundation
import AppKit
import SwiftUI
import Testing
import BopifyAuth
import BopifyDomain
import BopifyLibrary
import BopifyPlayback

@MainActor
@Suite("App authorization cancellation", .serialized)
struct AppEnvironmentAuthorizationTests {
    private let allLibraryScopes: Set<String> = ["user-library-read", "user-library-modify",
        "user-read-recently-played", "user-top-read", "playlist-read-private",
        "playlist-read-collaborative", "user-follow-read"]

    @Test(arguments: [Optional<Set<String>>.none, ["user-library-read"]])
    func restoredPlaybackWaitsForCompleteLibraryAccess(scopes: Set<String>?) async throws {
        let fixture = AuthorizationFixture(libraryScopes: scopes, startSignedOut: true)
        fixture.store.save(TokenSet(accessToken: "PLAYBACK", refreshToken: "REFRESH",
            expiresAt: .distantFuture, grantedScopes: ["streaming"]))

        await fixture.environment.restoreOrPromptSignIn()

        #expect(fixture.environment.authState == .needsLibraryAuthorization)
        #expect(fixture.environment.recovery == nil)
        #expect(fixture.environment.player == nil)
        #expect(fixture.browser.count == 0 && fixture.libraryBrowser.count == 0)
        #expect(fixture.store.load()?.accessToken == "PLAYBACK")
        await fixture.stop()
    }

    @Test func approvedSetupStartsPlayback() async throws {
        let fixture = AuthorizationFixture(approvedScopes: allLibraryScopes, startSignedOut: true)
        fixture.store.save(TokenSet(accessToken: "PLAYBACK", refreshToken: "REFRESH",
            expiresAt: .distantFuture, grantedScopes: ["streaming"]))
        await fixture.environment.restoreOrPromptSignIn()
        #expect(fixture.environment.authState == .needsLibraryAuthorization)
        #expect(fixture.environment.recovery == nil)

        await fixture.environment.completeLibrarySetup()
        #expect(fixture.environment.authState == .signedIn)
        #expect(fixture.environment.recovery != nil)
        await fixture.stop()
    }

    @Test func deniedSetupPreservesPlaybackGrantWithoutStartingThePlayer() async throws {
        let fixture = AuthorizationFixture(approvedScopes: [], startSignedOut: true)
        fixture.store.save(TokenSet(accessToken: "PLAYBACK", refreshToken: "REFRESH",
            expiresAt: .distantFuture, grantedScopes: ["streaming"]))
        await fixture.environment.restoreOrPromptSignIn()
        await fixture.environment.completeLibrarySetup()

        #expect(fixture.environment.authState == .needsLibraryAuthorization)
        #expect(fixture.environment.recovery == nil)
        #expect(fixture.environment.player == nil)
        #expect(fixture.environment.libraryAuthorizationNotice != nil)
        #expect(fixture.store.load()?.accessToken == "PLAYBACK")
        #expect(fixture.libraryStore.load()?.grantedScopes == ["user-library-read"])
        await fixture.stop()
    }

    @Test func completeSetupRestoresWithoutConsent() async throws {
        let fixture = AuthorizationFixture(libraryScopes: allLibraryScopes, startSignedOut: true)
        fixture.store.save(TokenSet(accessToken: "PLAYBACK", refreshToken: "REFRESH",
            expiresAt: .distantFuture, grantedScopes: ["streaming"]))
        await fixture.environment.restoreOrPromptSignIn()

        #expect(fixture.environment.authState == .signedIn)
        #expect(fixture.environment.recovery != nil)
        #expect(fixture.browser.count == 0 && fixture.libraryBrowser.count == 0)
        await fixture.stop()
    }

    @Test func revokedAccessReturnsToSetupAndRequiresANewCompleteGrant() async throws {
        let fixture = AuthorizationFixture(libraryScopes: allLibraryScopes, approvedScopes: allLibraryScopes,
            startSignedOut: true, libraryRevoked: true)
        fixture.store.save(TokenSet(accessToken: "PLAYBACK", refreshToken: "REFRESH",
            expiresAt: .distantFuture, grantedScopes: ["streaming"]))
        await fixture.environment.restoreOrPromptSignIn()
        #expect(fixture.environment.authState == .signedIn)
        let host = NSHostingView(rootView: PlayerRootView(environment: fixture.environment).frame(width: 410, height: 560))
        let window = NSWindow(contentRect: CGRect(x: 300, y: 300, width: 410, height: 560),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        fixture.environment.search.updateQuery("song")
        await fixture.environment.search.search()
        try await eventually { fixture.environment.authState == .needsLibraryAuthorization && fixture.environment.player == nil }
        #expect(fixture.environment.recovery == nil)
        #expect(fixture.libraryStore.load()?.accessToken == "LIBRARY")
        #expect(fixture.libraryBrowser.count == 0)

        await fixture.environment.completeLibrarySetup()
        #expect(fixture.environment.authState == .signedIn)
        #expect(fixture.libraryStore.load()?.accessToken == "AUTHORIZED_LIBRARY")
        await fixture.stop()
    }

    @Test func changingTheClientRequiresSetupBeforePlaybackCanResume() async throws {
        let fixture = AuthorizationFixture(libraryScopes: allLibraryScopes, startSignedOut: true)
        fixture.store.save(TokenSet(accessToken: "PLAYBACK", refreshToken: "REFRESH",
            expiresAt: .distantFuture, grantedScopes: ["streaming"]))
        await fixture.environment.restoreOrPromptSignIn()
        #expect(fixture.environment.authState == .signedIn)

        await fixture.environment.setLibraryClientID(String(repeating: "1", count: 32))
        try await eventually { fixture.libraryBrowser.count == 1 }
        #expect(fixture.environment.authState == .needsLibraryAuthorization)
        #expect(fixture.environment.player == nil && fixture.environment.recovery == nil)
        fixture.environment.cancelLibraryAuthorization()
        try await eventually { !fixture.environment.isAuthorizingLibrary }
        #expect(fixture.environment.authState == .needsLibraryAuthorization)
        #expect(fixture.store.load()?.accessToken == "PLAYBACK")
        await fixture.stop()
    }

    @Test func missingLibraryClientKeepsSetupRequired() async throws {
        let fixture = AuthorizationFixture(libraryScopes: allLibraryScopes, startSignedOut: true, libraryClientID: nil)
        fixture.store.save(TokenSet(accessToken: "PLAYBACK", refreshToken: "REFRESH",
            expiresAt: .distantFuture, grantedScopes: ["streaming"]))
        await fixture.environment.restoreOrPromptSignIn()
        #expect(fixture.environment.authState == .needsLibraryAuthorization)
        #expect(fixture.environment.player == nil && fixture.environment.recovery == nil)
        #expect(fixture.browser.count == 0 && fixture.libraryBrowser.count == 0)
        await fixture.stop()
    }

    @Test func clientChangeDuringRestorationCannotUseThePreviousGrant() async throws {
        let fixture = AuthorizationFixture(libraryScopes: allLibraryScopes, startSignedOut: true)
        fixture.store.save(TokenSet(accessToken: "PLAYBACK", refreshToken: "REFRESH",
            expiresAt: .distantFuture, grantedScopes: ["streaming"]))
        fixture.libraryStore.armLoad()
        fixture.libraryStore.armClear()
        defer {
            fixture.libraryStore.loadRelease.signal()
            fixture.libraryStore.clearRelease.signal()
        }
        let restoring = Task { await fixture.environment.restoreOrPromptSignIn() }
        try await eventually { fixture.libraryStore.blockedLoads.count == 1 }
        let replacementStarted = AuthorizationCounter()
        let replacing = Task {
            replacementStarted.increment()
            await fixture.environment.setLibraryClientID(String(repeating: "1", count: 32))
        }
        try await eventually { replacementStarted.count == 1 }
        fixture.libraryStore.loadRelease.signal()
        await restoring.value

        #expect(fixture.environment.authState == .needsLibraryAuthorization)
        #expect(fixture.environment.player == nil && fixture.environment.recovery == nil)
        fixture.libraryStore.clearRelease.signal()
        await replacing.value
        try await eventually { fixture.libraryBrowser.count == 1 }
        fixture.environment.cancelLibraryAuthorization()
        await fixture.stop()
    }

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

    @Test func librarySetupCancellationPreservesGrantsAndKeepsThePlayerUnavailable() async throws {
        let fixture = AuthorizationFixture(startSignedOut: true)
        fixture.store.save(TokenSet(accessToken: "PLAYBACK", refreshToken: "REFRESH",
            expiresAt: .distantFuture, grantedScopes: ["streaming"]))
        await fixture.environment.restoreOrPromptSignIn()
        let saved = fixture.libraryStore.load()
        let consent = Task { await fixture.environment.completeLibrarySetup() }
        try await eventually { fixture.libraryBrowser.count == 1 }
        fixture.environment.cancelLibraryAuthorization()
        try await eventually { !fixture.environment.isAuthorizingLibrary }
        await consent.value

        #expect(fixture.environment.authState == .needsLibraryAuthorization)
        #expect(fixture.environment.player == nil && fixture.environment.recovery == nil)
        #expect(fixture.environment.libraryAuthorizationNotice == nil)
        #expect(fixture.libraryStore.load() == saved)
        await fixture.stop()
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
            await fixture.environment.requireLibrarySetup()
            let library = Task { await fixture.environment.completeLibrarySetup() }
            try await eventually { fixture.libraryBrowser.count == 1 }
            let playback = Task { await fixture.environment.signIn() }
            try await eventually { fixture.browser.count == 1 }

            await fixture.environment.prepareForQuit()
            await playback.value
            await library.value

            #expect(!fixture.environment.isAuthorizingPlayback)
            #expect(!fixture.environment.isAuthorizingLibrary)
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

    init(libraryScopes: Set<String>? = ["user-library-read"], approvedScopes: Set<String>? = nil,
         startSignedOut: Bool = false, libraryClientID: String? = String(repeating: "0", count: 32),
         libraryRevoked: Bool = false) {
        libraryStore = AuthorizationStore(libraryScopes.map { TokenSet(accessToken: "LIBRARY", refreshToken: "REFRESH",
            expiresAt: .distantFuture, grantedScopes: $0) })
        let consentStore = libraryStore
        let playback = SpotifyAuthService(clientID: "test", store: store,
            openURL: { [browser] _ in browser.increment() })
        let library = SpotifyAuthService(clientID: "test-library", store: libraryStore,
            openURL: { [libraryBrowser] _ in libraryBrowser.increment() })
        playbackAuth = playback
        libraryAuth = library
        let services = AuthorizationLibrary(revoked: libraryRevoked)
        environment = AppEnvironment(previewPlayer: startSignedOut ? nil : player,
            favoriteService: services, searchService: services,
            authorizeLibrary: {
                let scopes = LibraryAuthorization.requiredScopes
                if let approvedScopes {
                    guard scopes.isSubset(of: approvedScopes) else { throw PlayerError.authDenied }
                    try await library.signOutAndClearCredentials()
                    consentStore.save(TokenSet(accessToken: "AUTHORIZED_LIBRARY", refreshToken: "REFRESH",
                        expiresAt: .distantFuture, grantedScopes: scopes))
                } else {
                    _ = try await library.authorizeLibrary()
                }
            },
            playbackAuth: playback, libraryAuth: library, previewLibraryClientID: libraryClientID,
            recoveryEngineFactory: { _, _ in throw PlayerError.networkUnavailable })
    }

    func stop() async {
        store.loadRelease.signal()
        libraryStore.loadRelease.signal()
        libraryStore.clearRelease.signal()
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
    private var holdNextClear = false
    let blockedLoads = AuthorizationCounter()
    let loadRelease = DispatchSemaphore(value: 0)
    let clearRelease = DispatchSemaphore(value: 0)

    init(_ tokens: TokenSet? = nil) { self.tokens = tokens }
    func save(_ tokens: TokenSet) { lock.withLock { self.tokens = tokens } }
    func clear() {
        let hold = lock.withLock {
            let value = holdNextClear
            holdNextClear = false
            return value
        }
        if hold { clearRelease.wait() }
        lock.withLock { tokens = nil }
    }
    func armLoad() { lock.withLock { holdNextLoad = true } }
    func armClear() { lock.withLock { holdNextClear = true } }
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

private struct AuthorizationLibrary: LibraryService, TrackSearchService {
    var revoked = false
    func savedState(for uri: SpotifyURI) async throws -> Bool {
        if revoked { throw LibraryError.authorizationRequired }
        return true
    }
    func save(_ uri: SpotifyURI) async throws {}
    func remove(_ uri: SpotifyURI) async throws {}
    func searchTracks(query: String, offset: Int, limit: Int) async throws -> TrackSearchPage {
        if revoked { throw LibraryError.authorizationRequired }
        return TrackSearchPage(tracks: [], nextOffset: nil)
    }
}
#endif
