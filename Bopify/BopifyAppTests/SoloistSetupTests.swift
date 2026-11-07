#if DEBUG
import Foundation
import Testing
import BopifyAuth
import BopifyDomain
import BopifyPlayback

private nonisolated final class SetupKeys: SoloistKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func load() throws -> String? { lock.withLock { value } }
    func save(_ key: String) throws { lock.withLock { value = key } }
    func clear() throws { lock.withLock { value = nil } }
}

extension LiveLyricTestEngine: PreparedPlaybackEngine {
    func adopt(initialVolume: Double) async throws { try await setVolume(initialVolume) }
    func activateForSetup() async throws { try await playHere() }
    func suspendDataServices() async {}
    func retryDataServices() async {}
}

@MainActor @Suite("Soloist native setup", .serialized)
struct SoloistSetupTests {
    @Test func retryingDiscoveryJoinsUnpairedSetupAndKeepsFallbackPlayback() async throws {
        let suite = "soloist-repair-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = LiveLyricTestEngine(), second = LiveLyricTestEngine()
        var starts = 0
        let controller = SoloistPlaybackController(defaults: defaults, keys: SetupKeys(), authorize: {},
            install: { _, _ in URL(fileURLWithPath: "/fixture/soloist") }, start: { request in
                starts += 1
                if starts == 1 {
                    request.available(first)
                    request.progress(.pairing("Bopify fixture"))
                    while true { try await Task.sleep(for: .milliseconds(10)) }
                }
                return second
            }, clearSession: {})
        let environment = makePreviewEnvironment(.playing, soloistController: controller)
        let track = environment.player?.state.currentTrack
        defer { environment.player?.stop() }
        let preparation = Task { await environment.enableSoloist(key: "fixture-key") }
        try await liveLyricEventually { if case .pairing = controller.phase { true } else { false } }
        await environment.retrySoloistPairing()
        await preparation.value
        #expect(starts == 2 && first.shutdowns == 1)
        #expect(controller.hasSavedKey && controller.phase == .prepared)
        #expect(environment.player?.state.currentTrack == track)
        #expect(environment.player?.state.phase == .playing)
        await controller.stop()
    }

    @Test func usablePlaybackRequiresAReadyCoreAndSurvivesOnlyCompanionFailure() async throws {
        let suite = "soloist-usable-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = LiveLyricTestEngine()
        var report: (@Sendable (SoloistEngineStatus) -> Void)?
        let controller = SoloistPlaybackController(defaults: defaults, keys: SetupKeys(), authorize: {},
            install: { _, _ in URL(fileURLWithPath: "/fixture/soloist") },
            start: { request in report = request.progress; return engine }, clearSession: {})
        #expect(!controller.hasUsablePlayback)
        #expect(await controller.enable(key: "fixture-key"))
        #expect(controller.phase == .prepared && !controller.hasUsablePlayback)
        _ = try await controller.makeEngine(accessToken: "fixture", configuration:
            PlaybackEngineConfiguration(deviceID: "fixture", startup: .coldLaunch),
            fallback: { _, _ in throw PlayerError.unknown })
        #expect(controller.hasUsablePlayback)
        report?(.servicesUnavailable)
        try await liveLyricEventually { controller.phase == .limitedServices }
        #expect(controller.hasUsablePlayback)
        report?(.failed(.startupFailed))
        try await liveLyricEventually { controller.phase == .failed(.startup) }
        #expect(controller.provider == .soloist && !controller.hasUsablePlayback)
        await controller.stop()
    }

    @Test func aSavedKeySelectsSoloistByDefaultBeforeSetupHasEverSucceeded() async throws {
        let suite = "soloist-default-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "soloist.hasKey")
        defaults.set(false, forKey: "soloist.enabled")
        let keys = SetupKeys(); try keys.save("fixture-key")
        let engine = LiveLyricTestEngine()
        var starts = 0
        let controller = SoloistPlaybackController(defaults: defaults, keys: keys,
            authorize: { Issue.record("Startup must not open consent") },
            install: { _, _ in URL(fileURLWithPath: "/fixture/soloist") },
            start: { _ in starts += 1; return engine }, clearSession: {})
        #expect(controller.prefersSoloist)
        let result = try await controller.makeEngine(accessToken: "fixture", configuration:
            PlaybackEngineConfiguration(deviceID: "fixture", startup: .coldLaunch),
            fallback: { _, _ in Issue.record("Saved-key default must start Soloist"); return engine })
        #expect(starts == 1 && controller.provider == .soloist)
        await result.shutdown()
    }

    @Test func retryingSpotifyServicesPreservesTheDefaultSoloistEngineDuringThrottling() async throws {
        let suite = "soloist-services-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "soloist.hasKey")
        let keys = SetupKeys(); try keys.save("fixture-key")
        let engine = LiveLyricTestEngine()
        let controller = SoloistPlaybackController(defaults: defaults, keys: keys,
            authorize: { throw SoloistPlaybackError.rateLimited },
            install: { _, _ in URL(fileURLWithPath: "/fixture/soloist") }, start: { _ in engine }, clearSession: {})
        _ = try await controller.makeEngine(accessToken: "fixture", configuration:
            PlaybackEngineConfiguration(deviceID: "fixture", startup: .coldLaunch), fallback: { _, _ in throw PlayerError.unknown })
        await controller.retryDataServices()
        #expect(controller.provider == .soloist && controller.prefersSoloist)
        #expect(controller.phase == .limitedServices && engine.shutdowns == 0)
        await controller.stop()
    }

    @Test func enablingLocalCoreDoesNotWaitForSpotifyServiceAuthorization() async throws {
        let suite = "soloist-local-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = LiveLyricTestEngine()
        let controller = SoloistPlaybackController(defaults: defaults, keys: SetupKeys(),
            authorize: { throw SoloistPlaybackError.rateLimited },
            install: { _, _ in URL(fileURLWithPath: "/fixture/soloist") }, start: { _ in engine }, clearSession: {})
        #expect(await controller.enable(key: "fixture-key"))
        #expect(controller.prefersSoloist)
        await controller.stop()
    }

    @Test func invalidKeyNeverStartsConsentOrInstallation() async throws {
        let suite = "soloist-setup-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let keys = SetupKeys()
        let controller = SoloistPlaybackController(defaults: defaults, keys: keys,
            authorize: { Issue.record("Invalid keys must not start consent") },
            install: { _, _ in Issue.record("Invalid keys must not download"); throw SoloistPlaybackError.unavailable },
            start: { _ in throw SoloistPlaybackError.unavailable }, clearSession: {})
        #expect(await !controller.enable(key: "two keys"))
        #expect(controller.phase == .failed(.invalidKey))
        #expect(try keys.load() == nil)
        #expect(!controller.prefersSoloist)
    }

    @Test func setupUsesSavedKeyAndKeepsPreferenceAfterSessionFallback() async throws {
        let suite = "soloist-setup-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let keys = SetupKeys(), engine = LiveLyricTestEngine()
        var consents = 0, downloads = 0, starts = 0
        let controller = SoloistPlaybackController(defaults: defaults, keys: keys,
            authorize: { consents += 1 }, install: { _, progress in
                downloads += 1; progress(.verifying)
                return URL(fileURLWithPath: "/fixture/soloist")
            }, start: { request in starts += 1; #expect(request.key == "fixture-key"); return engine }, clearSession: {})
        #expect(await controller.enable(key: "fixture-key"))
        #expect(controller.prefersSoloist && controller.hasSavedKey)
        #expect(consents == 0 && downloads == 1)
        #expect(starts == 1, "Prepare the muted Soloist session before asking the app to stop its current engine")
        let actual = try await controller.makeEngine(accessToken: "fixture", configuration:
            PlaybackEngineConfiguration(deviceID: "fixture", startup: .coldLaunch), fallback: { _, _ in throw PlayerError.unknown })
        #expect(ObjectIdentifier(actual as AnyObject) == ObjectIdentifier(engine))
        #expect(controller.provider == .soloist)
        await controller.useLibrespotForSession()
        #expect(controller.provider == .librespot)
        #expect(controller.prefersSoloist)
        #expect(try keys.load() == "fixture-key")
        await actual.shutdown()
        try controller.clearCredentials()
        #expect(try keys.load() == nil)
        #expect(!controller.prefersSoloist)
    }

    @Test func canceledSetupCannotActivateAnEngineThatFinishesLate() async throws {
        let suite = "soloist-setup-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let keys = SetupKeys(), lateEngine = LiveLyricTestEngine()
        let release = AsyncStream<Void>.makeStream()
        var started = false
        let controller = SoloistPlaybackController(defaults: defaults, keys: keys, authorize: {},
            install: { _, _ in URL(fileURLWithPath: "/fixture/soloist") }, start: { _ in
                started = true
                for await _ in release.stream { break }
                return lateEngine
            }, clearSession: {})
        let creating = Task { await controller.enable(key: "fixture-key") }
        try await liveLyricEventually { started }
        let canceling = Task { await controller.useLibrespotForSession() }
        try await liveLyricEventually { controller.sessionUsesLibrespot }
        release.continuation.finish()
        #expect(await !creating.value)
        await canceling.value
        #expect(lateEngine.shutdowns == 1)
        #expect(controller.provider == .librespot)
    }

    @Test func launchNeverPromptsForConsentAndUsesInactiveFallbackWhenTheKeyIsMissing() async throws {
        let suite = "soloist-setup-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "soloist.enabled")
        let engine = LiveLyricTestEngine()
        let controller = SoloistPlaybackController(defaults: defaults, keys: SetupKeys(),
            authorize: { Issue.record("Launch must not open OAuth") },
            install: { _, _ in Issue.record("Missing keys must not download"); throw SoloistPlaybackError.unavailable },
            start: { _ in throw SoloistPlaybackError.unavailable }, clearSession: {})
        _ = try await controller.makeEngine(accessToken: "fixture", configuration:
            PlaybackEngineConfiguration(deviceID: "fixture", startup: .coldLaunch), fallback: { _, options in
                #expect(options.startup == .recovery && options.snapshot == nil)
                return engine
            })
        #expect(controller.phase == .failed(.credentials))
        #expect(controller.provider == .librespot)
        await engine.shutdown()
    }

}
#endif
