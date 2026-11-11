#if DEBUG
import Foundation
import Observation
import Testing
import BopifyAuth
import BopifyDomain
import BopifyPlayback

private nonisolated final class SetupObservationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var changed = false
    func set() { lock.withLock { changed = true } }
    var value: Bool { lock.withLock { changed } }
}

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
    @Test func openingSetupDuringSessionRestorationCompletesWhenPlaybackBecomesReady() async throws {
        let suite = "soloist-restored-onboarding-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = LiveLyricTestEngine()
        let controller = SoloistPlaybackController(defaults: defaults, keys: SetupKeys(), authorize: {},
            install: { _, _ in URL(fileURLWithPath: "/fixture/soloist") },
            start: { _ in engine }, clearSession: {})
        #expect(await controller.enable(key: "fixture-key"))
        let environment = makePreviewEnvironment(.nothingPlaying, soloistController: controller)
        defer { environment.onboarding.cancel(); environment.player?.stop() }
        try #require(!controller.hasUsablePlayback)

        environment.showOnboarding()
        _ = try await controller.makeEngine(configuration:
            PlaybackEngineConfiguration(deviceID: "fixture", startup: .coldLaunch))
        try #require(controller.hasUsablePlayback)

        try await liveLyricEventually {
            environment.isShowingPlayer && !environment.onboarding.isArmed
        }
        #expect(environment.requestedOnboardingSection == nil)
        #expect(environment.onboardingStep == nil)
        await controller.stop()
    }

    @Test func recoveringFailedDiscoveryJoinsOwnedSetupAndPreservesTheExistingTrack() async throws {
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
                    request.progress(.failed(.discoveryUnavailable))
                    while true { try await Task.sleep(for: .milliseconds(10)) }
                }
                return second
            }, clearSession: {})
        let environment = makePreviewEnvironment(.playing, soloistController: controller)
        let track = environment.player?.state.currentTrack
        defer { environment.player?.stop() }
        let preparation = Task { await environment.enableSoloist(key: "fixture-key") }
        try await liveLyricEventually { controller.phase == .failed(.discovery) }
        await environment.resumeSoloistDiscovery()
        await preparation.value
        #expect(starts == 2 && first.shutdowns == 1)
        #expect(controller.hasSavedKey && controller.phase == .prepared)
        #expect(environment.player?.state.currentTrack == track)
        #expect(environment.player?.state.phase == .playing)
        await controller.stop()
    }

    @Test func cancelSetupInvalidatesAPendingFailedDiscoveryRecovery() async throws {
        let suite = "soloist-cancel-retry-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let keys = SetupKeys(), candidate = LiveLyricTestEngine()
        let release = AsyncStream<Void>.makeStream()
        defer { release.continuation.finish() }
        candidate.shutdownGate = { for await _ in release.stream { break } }
        var starts = 0
        let controller = SoloistPlaybackController(defaults: defaults, keys: keys, authorize: {},
            install: { _, _ in URL(fileURLWithPath: "/fixture/soloist") }, start: { request in
                starts += 1
                request.available(candidate)
                request.progress(.failed(.discoveryUnavailable))
                while true { try await Task.sleep(for: .milliseconds(10)) }
            }, clearSession: {})
        let environment = makePreviewEnvironment(.playing, soloistController: controller)
        defer { environment.player?.stop() }
        let preparing = Task { await environment.enableSoloist(key: "fixture-key") }
        try await liveLyricEventually { controller.phase == .failed(.discovery) }
        let retrying = Task { await environment.resumeSoloistDiscovery() }
        try await liveLyricEventually { candidate.shutdowns == 1 && environment.isRestartingSoloistPairing }
        await environment.cancelSoloistSetup()
        release.continuation.finish()
        await retrying.value
        await preparing.value
        #expect(starts == 1 && candidate.shutdowns == 1)
        #expect(!environment.isRestartingSoloistPairing && !controller.isPreparing)
        #expect(controller.hasSavedKey && controller.phase == .idle)
        #expect(environment.onboardingStep == .playback(.entry))
        #expect(try keys.load() == "fixture-key")
    }

    @Test func recoveryOpportunityDoesNotRestartHealthyPairing() async throws {
        let suite = "soloist-healthy-pairing-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let candidate = LiveLyricTestEngine()
        var starts = 0
        let controller = SoloistPlaybackController(defaults: defaults, keys: SetupKeys(), authorize: {},
            install: { _, _ in URL(fileURLWithPath: "/fixture/soloist") }, start: { request in
                starts += 1
                request.available(candidate)
                request.progress(.pairing(request.name))
                while true { try await Task.sleep(for: .milliseconds(10)) }
            }, clearSession: {})
        let environment = makePreviewEnvironment(.playing, soloistController: controller)
        let track = environment.player?.state.currentTrack
        defer { environment.player?.stop() }
        let preparing = Task { await environment.enableSoloist(key: "fixture-key") }
        try await liveLyricEventually { if case .pairing = controller.phase { true } else { false } }
        await environment.resumeSoloistDiscovery()
        #expect(starts == 1 && candidate.shutdowns == 0 && controller.isPreparing)
        #expect(environment.player?.state.currentTrack == track && environment.player?.state.phase == .playing)
        await environment.cancelSoloistSetup()
        await preparing.value
    }

    @Test func failedDiscoveryRetryKeepsTheControllerDeviceNameAndSavedKey() async throws {
        let suite = "soloist-stable-name-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = LiveLyricTestEngine(), keys = SetupKeys()
        var names: [String] = []
        let controller = SoloistPlaybackController(defaults: defaults, keys: keys, authorize: {},
            install: { _, _ in URL(fileURLWithPath: "/fixture/soloist") }, start: { request in
                names.append(request.name)
                #expect(request.key == "fixture-key")
                if names.count == 1 { throw SoloistPlaybackError.discoveryUnavailable }
                return engine
            }, clearSession: {})
        #expect(await !controller.enable(key: "fixture-key"))
        #expect(controller.phase == .failed(.discovery))
        await controller.stop()
        #expect(await controller.enable(key: ""))
        #expect(names.count == 2 && names[0] == names[1])
        #expect(names.first?.hasPrefix("Bopify ") == true)
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
        report?(.ready)
        try await liveLyricEventually { controller.phase == .ready }
        #expect(!controller.hasUsablePlayback, "A core status alone cannot claim the unadopted engine")
        let changed = SetupObservationFlag()
        withObservationTracking { _ = controller.hasUsablePlayback } onChange: { changed.set() }
        _ = try await controller.makeEngine(configuration:
            PlaybackEngineConfiguration(deviceID: "fixture", startup: .coldLaunch))
        #expect(controller.hasUsablePlayback && changed.value)
        report?(.servicesUnavailable)
        try await liveLyricEventually { controller.phase == .limitedServices }
        #expect(controller.hasUsablePlayback)
        report?(.failed(.startupFailed))
        try await liveLyricEventually { controller.phase == .failed(.startup) }
        #expect(!controller.hasUsablePlayback)
        await controller.stop()
    }

    @Test func aSavedKeySelectsSoloistByDefaultBeforeSetupHasEverSucceeded() async throws {
        let suite = "soloist-default-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "soloist.hasKey")
        let keys = SetupKeys(); try keys.save("fixture-key")
        let engine = LiveLyricTestEngine()
        var starts = 0
        let controller = SoloistPlaybackController(defaults: defaults, keys: keys,
            authorize: { Issue.record("Startup must not open consent") },
            install: { _, _ in URL(fileURLWithPath: "/fixture/soloist") },
            start: { _ in starts += 1; return engine }, clearSession: {})
        #expect(controller.hasSavedKey)
        let result = try await controller.makeEngine(configuration:
            PlaybackEngineConfiguration(deviceID: "fixture", startup: .coldLaunch))
        #expect(starts == 1 && controller.hasUsablePlayback)
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
        _ = try await controller.makeEngine(configuration:
            PlaybackEngineConfiguration(deviceID: "fixture", startup: .coldLaunch))
        await controller.retryDataServices()
        #expect(controller.hasUsablePlayback)
        #expect(controller.phase == .limitedServices && engine.shutdowns == 0)
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
        #expect(!controller.hasSavedKey)
    }

    @Test func setupAdoptsThePreparedSoloistAndClearsCredentialsOnlyWhenRequested() async throws {
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
        #expect(controller.hasSavedKey)
        #expect(consents == 0 && downloads == 1)
        #expect(starts == 1, "Prepare the muted Soloist session before asking the app to stop its current engine")
        let actual = try await controller.makeEngine(configuration:
            PlaybackEngineConfiguration(deviceID: "fixture", startup: .coldLaunch))
        #expect(ObjectIdentifier(actual as AnyObject) == ObjectIdentifier(engine))
        #expect(controller.hasUsablePlayback)
        await controller.stop()
        #expect(!controller.hasUsablePlayback)
        #expect(controller.hasSavedKey)
        #expect(try keys.load() == "fixture-key")
        await actual.shutdown()
        try controller.clearCredentials()
        #expect(try keys.load() == nil)
        #expect(!controller.hasSavedKey)
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
        let canceling = Task { await controller.cancelSetup() }
        await Task.yield()
        release.continuation.finish()
        #expect(await !creating.value)
        await canceling.value
        #expect(lateEngine.shutdowns == 1)
        #expect(!controller.hasUsablePlayback)
        #expect(controller.hasSavedKey && controller.phase == .idle)
    }

    @Test func missingKeyNeverInstallsStartsOrCreatesAudio() async throws {
        let suite = "soloist-missing-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = SoloistPlaybackController(defaults: defaults, keys: SetupKeys(),
            authorize: { Issue.record("Launch must not open OAuth") },
            install: { _, _ in Issue.record("Missing keys must not download"); throw SoloistPlaybackError.unavailable },
            start: { _ in Issue.record("Missing keys must not create audio"); throw SoloistPlaybackError.unavailable }, clearSession: {})
        await #expect(throws: SoloistKeyError.self) {
            _ = try await controller.makeEngine(configuration: PlaybackEngineConfiguration(deviceID: "fixture", startup: .coldLaunch))
        }
        #expect(controller.phase == .failed(.credentials))
        #expect(!controller.hasSavedKey && !controller.hasUsablePlayback)
    }

    @Test func failedSoloistStartPropagatesWithoutCreatingAnotherPlaybackEngine() async throws {
        let suite = "soloist-only-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "soloist.hasKey")
        let keys = SetupKeys(); try keys.save("fixture-key")
        var starts = 0
        let controller = SoloistPlaybackController(defaults: defaults, keys: keys, authorize: {},
            install: { _, _ in URL(fileURLWithPath: "/fixture/soloist") }, start: { _ in
                starts += 1
                throw SoloistPlaybackError.startupFailed
            }, clearSession: {})
        await #expect(throws: SoloistPlaybackError.self) {
            _ = try await controller.makeEngine(configuration: PlaybackEngineConfiguration(deviceID: "fixture", startup: .coldLaunch))
        }
        #expect(starts == 1 && !controller.hasUsablePlayback)
        #expect(controller.phase == .failed(.startup) && controller.hasSavedKey)
        #expect(try keys.load() == "fixture-key")
    }

    @Test(arguments: [SoloistPlaybackError.discoveryUnavailable, .invalidKey])
    func SDKInitializationFailureOffersSpecificSetupRecovery(error: SoloistPlaybackError) async throws {
        let suite = "soloist-discovery-failure-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = SoloistPlaybackController(defaults: defaults, keys: SetupKeys(), authorize: {},
            install: { _, _ in URL(fileURLWithPath: "/fixture/soloist") },
            start: { _ in throw error }, clearSession: {})
        #expect(await !controller.enable(key: "fixture-key"))
        #expect(controller.phase == .failed(error == .invalidKey ? .invalidKey : .discovery))
        #expect(controller.hasSavedKey && !controller.hasUsablePlayback)
    }

    @Test func cancelSetupStopsTheOwnedCandidateAndRetryUsesTheSavedKey() async throws {
        let suite = "soloist-cancel-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let keys = SetupKeys(), candidate = LiveLyricTestEngine(), replacement = LiveLyricTestEngine()
        var starts = 0
        let controller = SoloistPlaybackController(defaults: defaults, keys: keys, authorize: {},
            install: { _, _ in URL(fileURLWithPath: "/fixture/soloist") }, start: { request in
                starts += 1
                #expect(request.key == "fixture-key")
                if starts == 1 {
                    request.available(candidate)
                    request.progress(.pairing("Fixture"))
                    while true { try await Task.sleep(for: .milliseconds(10)) }
                }
                return replacement
            }, clearSession: {})
        let preparing = Task { await controller.enable(key: "fixture-key") }
        try await liveLyricEventually { if case .pairing = controller.phase { true } else { false } }
        await controller.cancelSetup()
        #expect(await !preparing.value)
        #expect(candidate.shutdowns == 1 && !controller.isPreparing && !controller.hasUsablePlayback)
        #expect(controller.phase == .idle && controller.hasSavedKey)
        #expect(try keys.load() == "fixture-key")
        #expect(await controller.enable(key: ""))
        #expect(starts == 2 && controller.phase == .prepared)
        await controller.stop()
    }
}
#endif
