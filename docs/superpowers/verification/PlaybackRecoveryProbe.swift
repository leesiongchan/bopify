import AppKit
import SwiftUI
import ScreenCaptureKit
import BopifyAuth
import BopifyDomain
import BopifyPlayback
import BopifyLibrary

@main struct PlaybackRecoveryProbe {
    nonisolated static let uri = SpotifyURI("spotify:track:6rqhFgbbKwnb9MLmUQDhG6")!
    nonisolated static var track: Track { Track(uri: uri, title: "Recovery test", artists: [ArtistSummary(name: "Bopify")], albumTitle: nil, artwork: Artwork(url: previewArtworkURL(0)), durationMs: 240_000) }
    @MainActor static func settle() async { for _ in 0..<300 { await Task.yield() } }
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        Task { @MainActor in
            await run()
            app.terminate(nil)
        }
        app.run()
    }
    @MainActor static func run() async {
        _ = PlaybackConnectionStatusView(status: .offline, restorationUnavailable: false, onRetry: {}, onReconnect: {})
        let store = ProbeTokenStore(), libraryStore = ProbeTokenStore()
        let saved = TokenSet(accessToken: "PLAYBACK_FAKE", refreshToken: "RT_FAKE", expiresAt: .distantFuture, grantedScopes: ["streaming"])
        try! store.save(saved); try! libraryStore.save(saved)
        let opened = ProbeBrowser(), factory = ProbeFactory(), library = ProbeLibrary()
        let player = PlayerModel()
        let environment = AppEnvironment(previewPlayer: player, favoriteService: library, savedTracksService: library, historyService: library,
            playbackAuth: SpotifyAuthService(clientID: "probe", store: store, openURL: { _ in opened.record() }),
            libraryAuth: SpotifyAuthService(clientID: "probe", store: libraryStore), artworkStore: makePreviewArtworkStore(),
            recoveryEngineFactory: { token, options in try await factory.create(token, options) })
        await environment.restoreOrPromptSignIn(); await factory.waitForCount(1)
        precondition(environment.authState == .signedIn && environment.player === player)
        let first = ProbeEngine(); factory.release(first); await settle(); first.ready(); await settle()
        await environment.likedSongs.reveal(at: Date())
        first.emit(.volumeChanged(volume: 0)); first.emit(.shuffleChanged(true)); first.emit(.repeatChanged(.context)); await settle()
        let contents = environment.likedSongs.tracks
        let mode = environment.presentation.mode
        let artwork = environment.artworkStore.images[previewArtworkURL(0)]!
        first.emit(.sessionLost(.spircEnded)); await factory.waitForCount(2)
        precondition(first.shutdownCount == 1)
        precondition(factory.options[1].snapshot?.shouldResume == true)
        precondition(factory.options[1].snapshot?.volume == 0)
        precondition(factory.options[1].snapshot?.shuffleEnabled == true)
        precondition(environment.player === player && environment.presentation.mode == mode)
        precondition(environment.likedSongs.tracks == contents && libraryStore.load() == saved)
        precondition(environment.artworkStore.images[previewArtworkURL(0)] === artwork)
        let second = ProbeEngine(); factory.release(second); await settle(); second.ready(); await settle()
        precondition(environment.connectionStatus == .ready && player.isEngineReady)
        precondition(factory.options[0].deviceID == factory.options[1].deviceID)
        await environment.explore.reveal(at: Date())
        precondition(second.recordedCommands == ["radio"] && first.recordedCommands.isEmpty)
        precondition(opened.count == 0)
        // Sign-out rejects a blocking create before its serialized cleanup starts.
        second.emit(.sessionLost(.spircEnded)); await factory.waitForCount(3)
        let signOut = Task { await environment.signOut() }; await settle()
        let late = ProbeEngine(); factory.release(late); await signOut.value
        precondition(late.shutdownCount == 1 && environment.player == nil)
        precondition(store.load() == nil && libraryStore.load() == nil)
        await checkQuitAndInitialNetworkFailure()
        await checkPresentation()
        await checkRepeatedRecovery()
        print("PASS: stable player/library, serialized replacement, stable device ID, late-create sign-out, no unsolicited browser")
    }
    @MainActor static func checkRepeatedRecovery() async {
        let store = ProbeTokenStore(), factory = ProbeFactory()
        try! store.save(TokenSet(accessToken: "FAKE", refreshToken: "FAKE", expiresAt: .distantFuture, grantedScopes: ["streaming"]))
        let player = PlayerModel()
        let environment = AppEnvironment(previewPlayer: player, favoriteService: ProbeLibrary(), playbackAuth: SpotifyAuthService(clientID: "probe", store: store), artworkStore: makePreviewArtworkStore(), recoveryEngineFactory: { token, options in try await factory.create(token, options) })
        await environment.restoreOrPromptSignIn(); await factory.waitForCount(1)
        var engine = ProbeEngine(); factory.release(engine); await settle(); engine.ready(); await settle()
        for index in 0..<100 {
            let old = engine, target = player.state.queue!.next[0].target!
            let next = factory.options.count + 1
            old.emit(.sessionLost(.spircEnded)); await settle()
            environment.retryPlaybackConnection(); await factory.waitForCount(next)
            precondition(old.shutdownCount == 1 && old.terminationCount == 1)
            let frozen = player.displayPositionMs(at: .now)
            let volume = player.state.volume
            old.emit(.trackChanged(Track(uri: uri, title: "Stale engine", artists: [], albumTitle: nil, artwork: nil, durationMs: 1000)))
            old.emit(.playing(positionMs: 999_000)); old.emit(.volumeChanged(volume: 1)); old.emit(.sessionLost(.playerChannelClosed))
            player.togglePlayPause(); player.next(); player.setVolume(0.5); await settle()
            precondition(player.displayPositionMs(at: .now) == frozen && old.recordedCommands.isEmpty)
            if index % 10 == 0 {
                factory.fail(.networkUnavailable); await settle()
                environment.retryPlaybackConnection(); await factory.waitForCount(next + 1)
            }
            engine = ProbeEngine(); factory.release(engine); await settle(); engine.ready(); await settle()
            player.selectQueueEntry(target); await settle()
            precondition(engine.recordedCommands.isEmpty && engine.terminationCount == 0 && player.isEngineReady)
            precondition(player.state.currentTrack?.title == "Recovery test" && player.state.volume == volume)
            precondition(environment.player === player && environment.connectionStatus == .ready)
        }
        await environment.prepareForQuit()
        precondition(factory.maximumLiveEngines == 1 && factory.maximumConcurrentCreations == 1)
        precondition(factory.engines.allSatisfy { $0.shutdownCount == 1 && $0.terminationCount == 1 })
        print("PASS: 100 replacements + 10 failed creates; maximum one live engine/create/consumer, stale inputs ignored, every engine torn down")
    }

    @MainActor static func render() async { try? await Task.sleep(for: .milliseconds(700)) }
    @MainActor static func checkPresentation() async {
        let store = ProbeTokenStore(), factory = ProbeFactory(), library = ProbeLibrary()
        try! store.save(TokenSet(accessToken: "FAKE", refreshToken: "FAKE", expiresAt: .distantFuture, grantedScopes: ["streaming"]))
        let player = PlayerModel()
        let environment = AppEnvironment(previewPlayer: player, favoriteService: library, savedTracksService: library, historyService: library,
            playbackAuth: SpotifyAuthService(clientID: "probe", store: store, openURL: { _ in preconditionFailure("Unexpected browser") }), artworkStore: makePreviewArtworkStore(),
            recoveryEngineFactory: { token, options in try await factory.create(token, options) })
        await environment.restoreOrPromptSignIn(); await factory.waitForCount(1)
        var engine = ProbeEngine(); factory.release(engine); await settle(); engine.ready(); await settle()
        let status = StatusItemController(content: PlayerRootView(environment: environment), environment: environment)
        status.perform(NSSelectorFromString("statusItemClicked:"), with: nil)
        let panel = NSApp.windows.compactMap { $0 as? StatusPanel }.first!
        for mode in [PlayerMode.compact, .expanded, .queue] {
            environment.presentation.resetEngagement()
            environment.presentation.sendAttention(.visibility(true))
            if mode != .compact { environment.presentation.sendAttention(.accessibilityFocus(true)) }
            environment.presentation.requestQueue(mode == .queue)
            await render()
            for _ in 0..<30 where environment.playerWindowController.isTransitioning {
                try? await Task.sleep(for: .milliseconds(100))
            }
            precondition(!environment.playerWindowController.isTransitioning)
            let frame = panel.frame
            precondition(environment.presentation.mode == mode)
            await capture(panel, "\(mode.rawValue)-before")
            engine.emit(.sessionLost(.spircEnded)); await factory.waitForCount(factory.options.count + 1)
            await render()
            precondition(panel.frame == frame && environment.player === player)
            let frozen = player.displayPositionMs(at: .now)
            precondition(player.displayPositionMs(at: .now.addingTimeInterval(20)) == frozen)
            let commands = engine.recordedCommands
            panel.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!)
            player.next(); player.seek(to: 1000); player.setVolume(0.5)
            await settle(); precondition(engine.recordedCommands == commands)
            await capture(panel, "\(mode.rawValue)-reconnecting")
            if mode != .compact {
                precondition(enabled("Play", panel) == false)
                precondition(enabled("Retry now", panel) == true)
            } else { precondition(element("Reconnecting…", panel) != nil) }

            print("PASS: \(mode.rawValue) stable frame=\(frame.size), frozen position, blocked commands, accessible recovery action")
            environment.recovery!.setNetworkAvailable(false); await render()
            precondition(environment.connectionStatus == .offline && panel.frame == frame)
            await capture(panel, "\(mode.rawValue)-offline")
            environment.recovery!.setNetworkAvailable(true)
            engine = ProbeEngine(); factory.release(engine); await settle()
            engine.emit(.connectionReady(.unavailable)); await render()
            precondition(player.restorationUnavailable && panel.frame == frame)
            await capture(panel, "\(mode.rawValue)-unavailable")
            let nextCreation = factory.options.count + 1
            if mode == .compact {
                let button = popups(panel.contentView!).first!
                precondition(button.title == "Retry now", "Compact unavailable caption must fit")
                precondition(abs(button.bounds.width - (environment.playerWindowController.layout.recordDiameter - 24)) < 0.5,
                    "Compact native menu must honor its capsule width, actual=\(button.bounds.width)")
                precondition(captionFits(button) && button.accessibilityLabel() == "Playback couldn't be restored.")
                let item = button.menu!.items.dropFirst().first { $0.title == "Retry restoration" && $0.action != nil }!
                precondition(item.target is CompactPlaybackConnectionMenu.Handler, "Compact action lost its target")
                precondition(NSStringFromSelector(item.action!) == "performRecoveryAction:")
                precondition(NSApp.sendAction(item.action!, to: item.target, from: item))
                await settle()
                precondition(factory.options.count == nextCreation, "Compact retry did not create: \(environment.connectionStatus), unavailable=\(player.restorationUnavailable)")
            } else { environment.retryPlaybackConnection() }
            await factory.waitForCount(nextCreation)
            factory.fail(.authDenied); await render()
            precondition(environment.connectionStatus == .needsReauthentication && panel.frame == frame)
            await capture(panel, "\(mode.rawValue)-reauthorization")
            if mode != .compact { precondition(enabled("Reconnect Spotify", panel) == true) }
            if mode == .compact {
                let reconnectButton = popups(panel.contentView!).first!
                precondition(abs(reconnectButton.bounds.width - (environment.playerWindowController.layout.recordDiameter - 24)) < 0.5)
                precondition(reconnectButton.cell?.lineBreakMode == .byTruncatingTail)
                environment.recovery!.start(); await factory.waitForCount(factory.options.count + 1)
                factory.fail(.premiumRequired); await render()
                let button = popups(panel.contentView!).first!
                precondition(button.menu!.items.first!.image != nil && button.imagePosition == .imageOnly)
                precondition(button.menu!.items.dropFirst().contains { $0.title == String(localized: "error.premiumRequired") }, "Permanent error explanation must be visible in the menu")
                precondition(button.accessibilityLabel() == String(localized: "error.premiumRequired"))
                precondition(panel.frame == frame)
                await capture(panel, "compact-permanent")
            }
            environment.recovery!.start(); await factory.waitForCount(factory.options.count + 1)
            engine = ProbeEngine(); factory.release(engine); await settle(); engine.ready(); await render()
            precondition(panel.frame == frame && player.isEngineReady)
        }
        await environment.prepareForQuit()
        withExtendedLifetime(status) {}
    }
    @MainActor static func capture(_ panel: StatusPanel, _ name: String) async {
        do {
            let content = try await SCShareableContent.currentProcess
            let window = content.windows.first { $0.windowID == panel.windowNumber }!
            let config = SCStreamConfiguration()
            config.width = Int(panel.frame.width * 2); config.height = Int(panel.frame.height * 2)
            config.ignoreShadowsSingleWindow = true
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
            let url = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(name + ".png")
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: url)
            print("capture: \(name)")
        } catch { preconditionFailure("Capture failed: \(error)") }
    }
    @MainActor static func attribute(_ object: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() : nil
    }
    @MainActor static func popups(_ view: NSView) -> [NSPopUpButton] {
        (view as? NSPopUpButton).map { [$0] } ?? view.subviews.flatMap(popups)
    }
    @MainActor static func captionFits(_ button: NSPopUpButton) -> Bool {
        (button.title as NSString).size(withAttributes: [.font: button.font!]).width + 16 <= button.bounds.width
    }
    @MainActor static func tree(_ object: Any) -> [NSObject] {
        guard let object = object as? NSObject else { return [] }
        return [object] + ((attribute(object, "accessibilityChildren") as? [Any]) ?? []).flatMap(tree)
    }
    @MainActor static func element(_ label: String, _ panel: StatusPanel) -> NSObject? {
        tree(panel.contentView!).first { (attribute($0, "accessibilityLabel") as? String == label || attribute($0, "accessibilityTitle") as? String == label) }
    }
    @MainActor static func enabled(_ label: String, _ panel: StatusPanel) -> Bool? {
        guard let object = element(label, panel) else { return nil }
        let selector = NSSelectorFromString("isAccessibilityEnabled")
        typealias Action = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(object.method(for: selector), to: Action.self)(object, selector)
    }

    @MainActor static func checkQuitAndInitialNetworkFailure() async {
        let store = ProbeTokenStore(), opened = ProbeBrowser(), factory = ProbeFactory()
        let saved = TokenSet(accessToken: "SAVED_FAKE", refreshToken: "RT_FAKE", expiresAt: .distantFuture, grantedScopes: ["streaming"])
        try! store.save(saved)
        let environment = AppEnvironment(previewPlayer: PlayerModel(), favoriteService: ProbeLibrary(), playbackAuth: SpotifyAuthService(clientID: "probe", store: store, openURL: { _ in opened.record() }), recoveryEngineFactory: { token, options in try await factory.create(token, options) })
        await environment.restoreOrPromptSignIn(); await factory.waitForCount(1)
        factory.fail(.networkUnavailable); await settle()
        precondition(environment.authState == .signedIn && environment.connectionStatus == .reconnecting && opened.count == 0)
        environment.retryPlaybackConnection(); await factory.waitForCount(2)
        precondition(factory.options[1].startup == .coldLaunch)
        let quitting = Task { await environment.prepareForQuit() }; await settle()
        let late = ProbeEngine(); factory.release(late); await quitting.value
        precondition(late.shutdownCount == 1 && environment.player == nil && store.load() == saved)
        // A pending browser authorization must not block quit or erase the previous grant.
        let auth = SpotifyAuthService(clientID: "probe", store: store, openURL: { _ in opened.record() })
        let consenting = AppEnvironment(previewPlayer: PlayerModel(), favoriteService: ProbeLibrary(), playbackAuth: auth)
        let signIn = Task { await consenting.signIn() }
        while opened.count == 0 { await Task.yield() }
        await consenting.prepareForQuit(); await signIn.value
        precondition(consenting.player == nil && store.load() == saved)
        print("PASS: initial network retry uses cold launch, late-create quit, pending OAuth quit preserves grant")
    }

}

nonisolated final class ProbeTokenStore: TokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: TokenSet?
    nonisolated func load() -> TokenSet? { lock.withLock { tokens } }
    nonisolated func save(_ value: TokenSet) throws { lock.withLock { tokens = value } }
    nonisolated func clear() throws { lock.withLock { tokens = nil } }
}
nonisolated final class ProbeBrowser: @unchecked Sendable {
    private let lock = NSLock()
    private var opens = 0
    nonisolated var count: Int { lock.withLock { opens } }
    nonisolated func record() { lock.withLock { opens += 1 } }
}
@MainActor final class ProbeFactory {
    var options: [PlaybackEngineConfiguration] = []
    var engines: [ProbeEngine] = []
    var maximumLiveEngines = 0
    var maximumConcurrentCreations = 0
    private var concurrentCreations = 0
    private var pending: CheckedContinuation<any ManagedPlaybackEngine, any Error>?
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    func create(_ token: String, _ options: PlaybackEngineConfiguration) async throws -> any ManagedPlaybackEngine {
        self.options.append(options)
        concurrentCreations += 1
        maximumConcurrentCreations = max(maximumConcurrentCreations, concurrentCreations)
        defer { concurrentCreations -= 1 }
        return try await withCheckedThrowingContinuation { pending = $0
            for (count, waiter) in waiters where self.options.count >= count { waiter.resume() }
            waiters.removeAll { self.options.count >= $0.0 }
        }
    }
    func waitForCount(_ count: Int) async { if options.count >= count { return }; await withCheckedContinuation { waiters.append((count, $0)) } }
    func release(_ engine: ProbeEngine) {
        engines.append(engine)
        maximumLiveEngines = max(maximumLiveEngines, engines.filter { $0.shutdownCount == 0 }.count)
        pending?.resume(returning: engine); pending = nil
    }
    func fail(_ error: PlayerError) { pending?.resume(throwing: error); pending = nil }
}
nonisolated final class ProbeEngine: ManagedPlaybackEngine, @unchecked Sendable {
    nonisolated let events: AsyncStream<PlaybackEvent>
    nonisolated private let continuation: AsyncStream<PlaybackEvent>.Continuation
    private let lock = NSLock()
    private var shutdowns = 0
    private var terminations = 0
    private var commands: [String] = []
    nonisolated var shutdownCount: Int { lock.withLock { shutdowns } }
    nonisolated var terminationCount: Int { lock.withLock { terminations } }
    nonisolated var recordedCommands: [String] { lock.withLock { commands } }
    nonisolated init() {
        (events, continuation) = AsyncStream.makeStream()
        continuation.onTermination = { [weak self] _ in self?.lock.withLock { self?.terminations += 1 } }
    }
    nonisolated func emit(_ event: PlaybackEvent) { continuation.yield(event) }
    nonisolated func ready() {
        emit(.trackChanged(PlaybackRecoveryProbe.track)); emit(.recoveryIdentity(PlaybackIdentity(trackURI: PlaybackRecoveryProbe.uri)))
        emit(.queueChanged(PlaybackQueue(generation: 1, previous: [],
            current: QueueEntry(id: "probe-current", uri: PlaybackRecoveryProbe.uri, target: nil, track: PlaybackRecoveryProbe.track, metadataFailed: false),
            next: [QueueEntry(id: "probe-next", uri: PlaybackRecoveryProbe.uri, target: QueueTarget(generation: 1, rawNextIndex: 0), track: PlaybackRecoveryProbe.track, metadataFailed: false)])))
        emit(.playing(positionMs: 12_000)); emit(.connectionReady(.local(PlaybackIdentity(trackURI: PlaybackRecoveryProbe.uri))))
    }
    nonisolated func shutdown() async { lock.withLock { shutdowns += 1 }; continuation.finish() }
    nonisolated func record(_ name: String) { lock.withLock { commands.append(name) } }
    nonisolated func load(_ request: PlayRequest) async throws { record("load") }
    nonisolated func resume() async throws { record("resume") }
    nonisolated func playHere() async throws { record("playHere") }
    nonisolated func pause() async throws { record("pause") }
    nonisolated func next() async throws { record("next") }
    nonisolated func previous() async throws { record("previous") }
    nonisolated func seek(to milliseconds: Int64) async throws { record("seek") }
    nonisolated func setVolume(_ value: Double) async throws { record("volume") }
    nonisolated func selectQueueEntry(_ target: QueueTarget) async throws { record("queue") }
    nonisolated func setShuffle(_ enabled: Bool) async throws { record("shuffle") }
    nonisolated func setRepeat(_ mode: RepeatMode) async throws { record("repeat") }
    nonisolated func requestRadio(seed: SpotifyURI) async throws -> RadioMix { record("radio"); return RadioMix(contextURI: seed, tracks: [PlaybackRecoveryProbe.track]) }
}
actor ProbeLibrary: LibraryService, SavedTracksService, ListeningHistoryService {
    func recentlyPlayed() async throws -> [RecentPlay] { [] }
    func topItems(_ kind: TopItemKind) async throws -> [StationSeed] { [StationSeed(uri: PlaybackRecoveryProbe.uri, name: "Probe station")] }
    func savedState(for uri: SpotifyURI) async throws -> Bool { false }
    func save(_ uri: SpotifyURI) async throws {}
    func remove(_ uri: SpotifyURI) async throws {}
    func savedTracks(offset: Int, limit: Int) async throws -> SavedTracksPage { SavedTracksPage(tracks: [PlaybackRecoveryProbe.track], nextOffset: nil, total: 1) }
}
