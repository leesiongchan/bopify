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
    func retryDataServices() async {}
}

@MainActor @Suite("Soloist native setup", .serialized)
struct SoloistSetupTests {
    @Test func missingInstallationGrantNeverOpensADialogDuringRestore() throws {
        let suite = "soloist-scope-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let access = SoloistInstallationAccess(defaults: defaults)
        #expect(throws: SoloistInstallationAccessError.self) { try access.restore() }
        #expect(defaults.data(forKey: SoloistInstallationAccess.bookmarkKey) == nil)
        defaults.set(Data("invalid-bookmark".utf8), forKey: SoloistInstallationAccess.bookmarkKey)
        #expect(throws: (any Error).self) { try access.restore() }
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
        #expect(consents == 1 && downloads == 1)
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
