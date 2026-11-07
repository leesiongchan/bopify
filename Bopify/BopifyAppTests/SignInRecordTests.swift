import AppKit
import SwiftUI
import Testing
import BopifyDomain
import BopifyAuth
import BopifyPlayback

@MainActor @Suite("Startup record")
struct SignInRecordTests {
    @Test(arguments: [StartupStep.signIn(.idle), .library(.idle)])
    func idleStepsInviteWithTheRecordOutOfItsSleeve(step: StartupStep) {
        #expect(step.recordPose == .out)
    }

    @Test(arguments: [StartupStep.signIn(.authenticating), .signIn(.restoring), .signIn(.removingCredentials), .library(.authorizing),
                      .connection(messageKey: "connection.reconnecting", isFailure: false)])
    func workInProgressSpinsTheRecord(step: StartupStep) {
        #expect(step.recordPose == .spinning)
    }

    @Test(arguments: [StartupStep.signIn(.error(.credentialCorrupt)), .signIn(.error(.credentialCleanupRequired)), .library(.refused),
                      .connection(messageKey: "connection.offline", isFailure: true)])
    func failuresTuckTheRecordBackIn(step: StartupStep) {
        #expect(step.recordPose == .tucked)
    }

    @Test func librarySetupIsTheSecondSideOfTheRecord() {
        #expect(StartupStep.signIn(.idle).progress == 1 && StartupStep.signIn(.idle).side == .a)
        #expect(StartupStep.library(.idle).progress == 2 && StartupStep.library(.idle).side == .b)
    }

    @Test func playbackIsTheThirdInlineStage() {
        #expect(StartupStep.playback(.entry).progress == 3)
        #expect(StartupStep.playback(.working).recordPose == .spinning)
        #expect(StartupStep.playback(.failure).recordPose == .tucked)
        #expect(StartupStep.playback(.entry).identity == StartupStep.playback(.working).identity)
    }

    @Test func reopeningSetupUsesTheMainSurfaceAndExpandedGeometry() {
        let environment = makePreviewEnvironment(.playing)
        defer { environment.player?.stop() }
        environment.showOnboarding(section: .playback)
        #expect(environment.isShowingOnboarding)
        #expect(environment.playerMode == .expanded)
        #expect(environment.onboardingStep == .playback(.entry))
        environment.closeOnboarding()
        #expect(!environment.isShowingOnboarding)
    }

    @Test func missingSoloistKeyRequiresSetupDespiteAnExistingTrack() async throws {
        let suite = "onboarding-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = SoloistPlaybackController(defaults: defaults, keys: OnboardingKeys(), authorize: {},
            install: { _, _ in throw SoloistPlaybackError.unavailable }, clearSession: {})
        let environment = makePreviewEnvironment(.playing, soloistController: controller)
        let track = environment.player?.state.currentTrack
        defer { environment.player?.stop() }
        #expect(environment.isListening)
        #expect(environment.onboardingStep == .playback(.entry))
        #expect(environment.playerMode == .expanded)
        await environment.enableSoloist(key: "fixture-key")
        #expect(environment.onboardingStep == .playback(.failure))
        #expect(environment.player?.state.currentTrack == track)
        await environment.cancelSoloistSetup()
        #expect(environment.isShowingOnboarding)
        #expect(environment.onboardingStep == .playback(.entry))
        #expect(controller.hasSavedKey && !controller.hasUsablePlayback)
    }

    @Test func connectingKeepsWhicheverSideIsShowing() {
        #expect(StartupStep.connection(messageKey: "connection.reconnecting", isFailure: false).side == nil)
    }

    @Test(arguments: [StartupStep.signIn(.restoring), .signIn(.removingCredentials), .connection(messageKey: "connection.reconnecting", isFailure: false)])
    func returningUsersSeeNoSetupProgress(step: StartupStep) {
        #expect(step.progress == nil)
    }
}

@MainActor @Suite("Startup connection")
struct StartupConnectionTests {
    private func connection(_ status: PlaybackConnectionStatus, restorationUnavailable: Bool = false,
                            isAuthorizing: Bool = false, offersRetry: Bool = false) -> PlaybackConnectionStatusView {
        PlaybackConnectionStatusView(status: status, restorationUnavailable: restorationUnavailable, hasConnected: true,
                                     onRetry: {}, onReconnect: {}, offersRetry: offersRetry, isAuthorizing: isAuthorizing)
    }

    @Test(arguments: [PlaybackConnectionStatus.connecting, .restoring, .reconnecting, .stopped])
    func workInProgressIsNotAFailure(status: PlaybackConnectionStatus) {
        #expect(!connection(status).isFailure)
    }

    @Test(arguments: [PlaybackConnectionStatus.offline, .needsReauthentication, .failed(.networkUnavailable)])
    func troubleTheUserMustActOnIsAFailure(status: PlaybackConnectionStatus) {
        #expect(connection(status).isFailure)
    }

    /// Short waits retry on their own, so a manual retry would add nothing.
    @Test(arguments: [PlaybackConnectionStatus.connecting, .restoring, .reconnecting, .offline])
    func shortWaitsOfferNoManualRetry(status: PlaybackConnectionStatus) {
        #expect(connection(status).actionKey == nil)
    }

    @Test(arguments: [PlaybackConnectionStatus.connecting, .reconnecting, .offline])
    func longWaitsOfferRetryNow(status: PlaybackConnectionStatus) {
        #expect(connection(status, offersRetry: true).actionKey == "connection.retry")
    }

    @Test(arguments: [PlayerError.premiumRequired, .accountRestricted, .unknown, .networkUnavailable])
    func everyFailureOffersRetryNow(error: PlayerError) {
        #expect(connection(.failed(error)).actionKey == "connection.retry")
    }

    @Test func credentialFailuresKeepTheirOwnActions() {
        #expect(connection(.failed(.credentialCorrupt)).actionKey == "connection.reconnect")
        #expect(connection(.failed(.credentialUnavailable)).actionKey == "connection.retryCredentials")
    }

    @Test func unrestorablePlaybackIsAFailureButAuthorizingIsNot() {
        #expect(connection(.ready, restorationUnavailable: true).isFailure)
        #expect(!connection(.offline, isAuthorizing: true).isFailure)
    }
}

@MainActor @Suite("Startup shell", .serialized)
struct StartupShellTests {
    @Test func openingSetupExpandsTheExistingRecordPanel() async throws {
        _ = NSApplication.shared
        let keys = ["player.frame", "player.keepOnTop", "player.recordCenter"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        let environment = makePreviewEnvironment(.playing)
        let controller = StatusItemController(content: PlayerRootView(environment: environment), environment: environment)
        let panel = try #require(NSApp.windows.compactMap { $0 as? StatusPanel }
            .first { !existing.contains(ObjectIdentifier($0)) })
        panel.isReleasedWhenClosed = false
        defer { withExtendedLifetime(controller) { panel.close() }; environment.player?.stop() }
        environment.showOnboarding()
        try await liveLyricEventually { panel.frame.width >= 410 && panel.frame.height >= 560 }
        #expect(environment.isShowingOnboarding)
        #expect(!panel.hasShadow)
        environment.closeOnboarding()
        try await liveLyricEventually { panel.frame.width < 410 }
    }

    @Test func startupGlassHasNoNativeOutline() throws {
        _ = NSApplication.shared
        let keys = ["player.frame", "player.keepOnTop", "player.recordCenter"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        let existingWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let environment = makePreviewEnvironment(.nothingPlaying)
        defer { environment.player?.stop() }
        try #require(!environment.isListening, "The startup shell only shows while nothing is listening")
        let controller = StatusItemController(content: EmptyView(), environment: environment)
        let panel = try #require(NSApp.windows.compactMap { $0 as? StatusPanel }
            .first { !existingWindows.contains(ObjectIdentifier($0)) })
        panel.isReleasedWhenClosed = false
        defer { withExtendedLifetime(controller) { panel.close() } }
        #expect(!panel.hasShadow, "The native shadow traces the startup glass as a hard rectangular outline")
    }
}

private nonisolated final class OnboardingKeys: SoloistKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func load() throws -> String? { lock.withLock { value } }
    func save(_ key: String) throws { lock.withLock { value = key } }
    func clear() throws { lock.withLock { value = nil } }
}
