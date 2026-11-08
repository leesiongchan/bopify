import AppKit
import SwiftUI
import Observation
import Testing
import BopifyDomain
import BopifyAuth
import BopifyPlayback

@MainActor @Suite("Startup record")
struct SignInRecordTests {
    @Test func hidingDuringTheFirstFlipHalfDoesNotLeaveTheReopenedRecordEdgeOn() async throws {
        _ = NSApplication.shared
        let fixture = InterruptedRecordFixture()
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 300, height: 360),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: InterruptedRecordView(fixture: fixture))
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(1300))
        try #require(fixture.recordFrame.width > 100)

        fixture.step = .library(.idle)
        try await Task.sleep(for: .milliseconds(150))
        fixture.isVisible = false
        try await Task.sleep(for: .milliseconds(100))
        fixture.isVisible = true
        try await Task.sleep(for: .milliseconds(1300))

        #expect(fixture.recordFrame.width > 100, "Reopening the same library step must restore the full record face")
    }

    @Test func libraryAndListeningKeepTheWelcomeRecordSize() throws {
        func renderedSize(_ step: StartupStep) throws -> CGSize {
            let renderer = ImageRenderer(content: SignInRecordView(step: step, isVisible: false))
            return try #require(renderer.nsImage?.size)
        }
        let welcome = try renderedSize(.signIn(.idle))
        #expect(welcome.width >= 200)
        for step: StartupStep in [.library(.idle), .library(.authorizing), .library(.connected), .library(.refused),
                                  .playback(.entry), .playback(.working), .playback(.failure), .completion] {
            #expect(try renderedSize(step) == welcome, "The hero must keep its visual presence throughout setup")
        }
    }

    @Test func armedReadySetupCannotShowPlayerBeforeCompletionStarts() {
        let environment = makePreviewEnvironment(.nothingPlaying)
        defer { environment.onboarding.cancel(); environment.player?.stop() }
        environment.onboarding.begin()
        #expect(environment.requestedOnboardingSection == nil)
        #expect(!environment.isShowingPlayer)
        #expect(environment.onboardingStep == .playback(.working))
        environment.updateOnboardingReadiness()
        #expect(environment.onboardingStep == .completion)
    }

    @Test func completedSetupKeepsTheRegularPlayerWhileIdle() {
        let environment = makePreviewEnvironment(.nothingPlaying)
        defer { environment.player?.stop() }
        #expect(!environment.isShowingOnboarding)
        #expect(environment.player?.state.currentTrack == nil)
        #expect(environment.playerMode == environment.presentation.mode)
        environment.showOnboarding(section: .playback)
        #expect(environment.isShowingOnboarding && environment.playerMode == .expanded)
        environment.closeOnboarding()
        #expect(environment.playerMode == environment.presentation.mode)
    }

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
        #expect(environment.onboardingStep == .completion)
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
        #expect(environment.player?.state.currentTrack != nil)
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
    @Test func openingSetupExpandsTheExistingIdleRecordPanel() async throws {
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
        let environment = makePreviewEnvironment(.nothingPlaying)
        let controller = StatusItemController(content: PlayerRootView(environment: environment), environment: environment)
        let panel = try #require(NSApp.windows.compactMap { $0 as? StatusPanel }
            .first { !existing.contains(ObjectIdentifier($0)) })
        panel.isReleasedWhenClosed = false
        defer { withExtendedLifetime(controller) { panel.close() }; environment.player?.stop() }
        #expect(environment.isShowingPlayer && environment.player?.state.currentTrack == nil)
        #expect(panel.frame.width < 410)
        environment.showOnboarding()
        try await liveLyricEventually {
            panel.frame.width >= 410 && abs(panel.frame.height - environment.startupWindow.height) < 1
        }
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
        environment.showOnboarding(section: .playback)
        try #require(environment.isShowingOnboarding, "The startup shell belongs to onboarding")
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

@MainActor @Observable private final class InterruptedRecordFixture {
    var step = StartupStep.signIn(.idle)
    var isVisible = true
    var recordFrame = CGRect.zero
}

private struct InterruptedRecordView: View {
    let fixture: InterruptedRecordFixture
    var body: some View {
        SignInRecordView(step: fixture.step, isVisible: fixture.isVisible,
                         onRecordFrameChanged: { fixture.recordFrame = $0 })
            .frame(width: 300, height: 360)
    }
}
