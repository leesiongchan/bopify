#if DEBUG
import Foundation
import AppKit
import SwiftUI
import Testing
import BopifyAuth
import BopifyDomain
import BopifyPlayback

@MainActor
@Suite("App live lyrics", .serialized, .timeLimit(.minutes(1)))
struct AppEnvironmentLyricsTests {
    @Test func quittingDisablesLyricsWhileEngineShutdownIsPending() async throws {
        try await withLyricsApp { f in
            try await f.ready()
            f.environment.showLiveLyrics()
            let (resume, continuation) = AsyncStream<Void>.makeStream()
            defer { continuation.finish() }
            f.first.shutdownGate = { for await _ in resume { break } }
            let quitting = Task { await f.environment.prepareForQuit() }
            try await liveLyricEventually { f.first.shutdowns == 1 }

            let controller = StatusItemController(content: EmptyView(), environment: f.environment)
            defer { withExtendedLifetime(controller) {} }
            let menu = NSMenu()
            let show = NSMenuItem(title: "Show", action: NSSelectorFromString("toggleLiveLyrics:"), keyEquivalent: "")
            let focus = NSMenuItem(title: "Focus", action: NSSelectorFromString("focusLiveLyrics:"), keyEquivalent: "")
            for item in [show, focus] { item.target = controller; menu.addItem(item) }
            menu.update()
            #expect(!show.isEnabled && !focus.isEnabled)
            f.environment.showLiveLyrics()
            f.environment.focusLiveLyrics()
            #expect(f.environment.liveLyricRibbon == nil && !f.environment.isLiveLyricsVisible)

            continuation.finish()
            await quitting.value
        }
    }

    @Test(arguments: ["signOut", "quit"])
    func nativeMenuDisablesLyricsAfterTeardown(action: String) async throws {
        try await withLyricsApp { f in
            try await f.ready()
            let controller = StatusItemController(content: EmptyView(), environment: f.environment)
            defer { withExtendedLifetime(controller) {} }
            let menu = NSMenu()
            let show = NSMenuItem(title: "Show", action: NSSelectorFromString("toggleLiveLyrics:"), keyEquivalent: "")
            let focus = NSMenuItem(title: "Focus", action: NSSelectorFromString("focusLiveLyrics:"), keyEquivalent: "")
            let quit = NSMenuItem(title: "Quit", action: NSSelectorFromString("quit:"), keyEquivalent: "")
            for item in [show, focus, quit] { item.target = controller; menu.addItem(item) }
            menu.update()
            #expect(show.isEnabled && focus.isEnabled && quit.isEnabled)

            if action == "signOut" { await f.environment.signOut() }
            else { await f.environment.prepareForQuit() }
            show.isEnabled = false; focus.isEnabled = false
            menu.update()
            #expect(!show.isEnabled && !focus.isEnabled)
            #expect(quit.isEnabled)
        }
    }

    @Test func ownsOneSessionAndRoutesToTheReadyEngine() async throws {
        try await withLyricsApp { f in
            try await f.ready()
            #expect(f.environment.liveLyricRibbon == nil)
            f.environment.showLiveLyrics()
            let session = try #require(f.environment.liveLyricRibbon)
            try await liveLyricEventually { f.firstGate.requests.count == 1 }
            f.firstGate.succeed(0, with: liveLyrics())
            try await liveLyricEventually { session.model.source != nil }
            session.model.holdText()
            let scroll = session.model.scrollResetRevision
            f.environment.showLiveLyrics(); f.environment.focusLiveLyrics()
            #expect(f.environment.liveLyricRibbon === session)
            #expect(session.model.isHeld && session.model.scrollResetRevision == scroll)
            #expect(f.firstGate.requests.count == 1 && f.first.commands.isEmpty)
            f.environment.hideLiveLyrics()
            #expect(!f.environment.isLiveLyricsVisible && session.model.source == nil)
            f.environment.showLiveLyrics()
            try await liveLyricEventually { f.firstGate.requests.count == 2 }
            #expect(f.environment.liveLyricRibbon === session)
        }
    }

    @Test func reconnectRoutesNewRequestsAndRejectsLateOldFailure() async throws {
        try await withLyricsApp { f in
            try await f.ready()
            f.environment.showLiveLyrics()
            try await liveLyricEventually { f.firstGate.requests.count == 1 }
            let player = try #require(f.environment.player)
            let epoch = player.engineEpoch
            f.first.emit(.sessionLost(.playerChannelClosed))
            try await liveLyricEventually { f.environment.recovery?.currentEngine as? LiveLyricTestEngine === f.second }
            f.emitReady(f.second)
            try await liveLyricEventually { f.secondGate.requests.count >= 1 && f.environment.connectionStatus == .ready }
            #expect(player.engineEpoch > epoch && f.environment.player === player)
            let last = f.secondGate.requests.last!.id
            f.secondGate.succeed(last, with: liveLyrics(displayName: "Current provider"))
            try await liveLyricEventually { f.environment.liveLyricRibbon?.model.source?.attribution == "Current provider" }
            f.firstGate.fail(0, with: PlayerError.playbackSessionLost)
            for _ in 0..<30 { await Task.yield() }
            #expect(f.environment.connectionStatus == .ready && f.factoryCount == 2)
            #expect(f.environment.liveLyricRibbon?.model.source?.attribution == "Current provider")
        }
    }

    @Test(arguments: [false, true])
    func serviceFailureAndSessionLossUseDifferentPaths(sessionLost: Bool) async throws {
        try await withLyricsApp { f in
            try await f.ready(); f.environment.showLiveLyrics()
            try await liveLyricEventually { f.firstGate.requests.count == 1 }
            if sessionLost { f.firstGate.fail(0, with: PlayerError.playbackSessionLost) }
            else { f.firstGate.fail(0, with: LyricFailure.network) }
            if sessionLost {
                try await liveLyricEventually { f.environment.recovery?.currentEngine as? LiveLyricTestEngine === f.second }
                #expect(f.first.shutdowns == 1)
            } else {
                try await liveLyricEventually { f.environment.liveLyricRibbon?.model.content == .failure }
                #expect(f.environment.connectionStatus == .ready && f.factoryCount == 1)
            }
            #expect(f.environment.authState == .signedIn)
        }
    }

    @Test(arguments: ["signOut", "quit"])
    func teardownStopsPendingLyricsAndPreventsReopening(action: String) async throws {
        try await withLyricsApp { f in
            try await f.ready(); f.environment.showLiveLyrics()
            let session = try #require(f.environment.liveLyricRibbon)
            try await liveLyricEventually { f.firstGate.requests.count == 1 }
            if action == "signOut" { await f.environment.signOut() }
            else { await f.environment.prepareForQuit() }
            #expect(f.environment.liveLyricRibbon == nil && !session.isVisible)
            try await liveLyricEventually { f.firstGate.cancelled.contains(0) }
            f.firstGate.succeed(0, with: liveLyrics())
            for _ in 0..<30 { await Task.yield() }
            f.environment.showLiveLyrics(); f.environment.focusLiveLyrics()
            #expect(f.environment.liveLyricRibbon == nil && session.model.source == nil)
        }
    }
}

@MainActor private func withLyricsApp(_ body: @MainActor (LyricsAppFixture) async throws -> Void) async throws {
    let fixture = LyricsAppFixture()
    do { try await body(fixture) }
    catch { await fixture.stop(); throw error }
    await fixture.stop()
}

@MainActor private final class LyricsAppFixture {
    let firstGate = LiveLyricRequestGate()
    let secondGate = LiveLyricRequestGate()
    let first: LiveLyricTestEngine
    let second: LiveLyricTestEngine
    let environment: AppEnvironment
    private let count: LyricsFactoryCount
    var factoryCount: Int { count.value }

    init() {
        let a = firstGate, b = secondGate
        let first = LiveLyricTestEngine { try await a.request(for: $0, epoch: nil) }
        let second = LiveLyricTestEngine { try await b.request(for: $0, epoch: nil) }
        self.first = first; self.second = second
        let count = LyricsFactoryCount(); self.count = count
        let grant = TokenSet(accessToken: "FAKE", refreshToken: "FAKE", expiresAt: .distantFuture, grantedScopes: ["streaming"])
        environment = AppEnvironment(previewPlayer: PlayerModel(), favoriteService: LyricsLibrary(),
            playbackAuth: SpotifyAuthService(clientID: "test", store: LyricsTokenStore(grant)),
            libraryAuth: SpotifyAuthService(clientID: "test-library", store: LyricsTokenStore(nil)),
            recoveryEngineFactory: { _, _ in count.next() == 1 ? first : second })
    }
    func ready() async throws {
        await environment.restoreOrPromptSignIn()
        try await liveLyricEventually { self.environment.recovery?.currentEngine as? LiveLyricTestEngine === self.first }
        emitReady(first)
        try await liveLyricEventually { self.environment.connectionStatus == .ready && self.environment.player?.state.phase == .paused }
    }
    func emitReady(_ engine: LiveLyricTestEngine) {
        engine.emit(.trackChanged(liveLyricTrack())); engine.emit(.queueChanged(liveLyricQueue()))
        engine.emit(.paused(positionMs: 1000))
        engine.emit(.connectionReady(.local(PlaybackIdentity(trackURI: liveLyricURI))))
    }
    func stop() async { await environment.prepareForQuit(); firstGate.finish(); secondGate.finish() }
}

private nonisolated final class LyricsFactoryCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func next() -> Int { lock.withLock { count += 1; return count } }
}

private nonisolated final class LyricsTokenStore: TokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: TokenSet?
    init(_ tokens: TokenSet?) { self.tokens = tokens }
    func save(_ tokens: TokenSet) { lock.withLock { self.tokens = tokens } }
    func load() -> TokenSet? { lock.withLock { tokens } }
    func clear() { lock.withLock { tokens = nil } }
}

private struct LyricsLibrary: LibraryService {
    func savedState(for uri: SpotifyURI) async throws -> Bool { false }
    func save(_ uri: SpotifyURI) async throws {}
    func remove(_ uri: SpotifyURI) async throws {}
}
#endif
