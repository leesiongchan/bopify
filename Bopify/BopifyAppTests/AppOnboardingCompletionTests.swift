import Testing
import Foundation
import BopifyDomain
import BopifyPlayback

@MainActor @Suite("App onboarding completion", .serialized)
struct AppOnboardingCompletionTests {
    @Test func armingSetupWithAlreadyReadyPlaybackCompletesWithoutAViewReadinessChange() async throws {
        let environment = makePreviewEnvironment(.nothingPlaying)
        defer { environment.onboarding.cancel(); environment.player?.stop() }
        try #require(environment.soloist.hasUsablePlayback)

        environment.onboarding.begin()

        try await liveLyricEventually {
            !environment.onboarding.isArmed && environment.onboarding.phase == .idle && environment.isShowingPlayer
        }
    }

    @Test func rateLimitedMetadataDoesNotHoldTheReadyScreenOpen() async throws {
        let suite = "onboarding-limited-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = SoloistPlaybackController(defaults: defaults,
            readyEngine: PreviewPlaybackEngine(tracks: [liveLyricTrack()]),
            authorize: { throw SoloistPlaybackError.rateLimited },
            install: { _, _ in throw SoloistPlaybackError.unavailable })
        await controller.retryDataServices()
        try #require(controller.phase == .limitedServices && controller.hasUsablePlayback)
        let environment = makePreviewEnvironment(.nothingPlaying, soloistController: controller)
        defer { environment.onboarding.cancel(); environment.player?.stop() }

        environment.onboarding.begin()

        try await liveLyricEventually { !environment.onboarding.isArmed && environment.isShowingPlayer }
    }

    @Test func openingAlreadyReadySetupCompletesWithoutAnExtraAction() async throws {
        let environment = makePreviewEnvironment(.nothingPlaying)
        defer { environment.onboarding.cancel(); environment.player?.stop() }
        let player = try #require(environment.player)
        environment.showOnboarding()

        try #require(environment.onboardingStep == .completion)
        #expect(environment.onboarding.isArmed)
        try await liveLyricEventually { environment.onboarding.phase == .idle && environment.isShowingPlayer }
        #expect(environment.requestedOnboardingSection == nil)
        #expect(environment.player === player)
        #expect(player.state.currentTrack == nil && player.state.phase == .idle)
    }

    @Test func repeatedReadySetupRequestsDoNotReopenTheCompletedStep() async throws {
        let environment = makePreviewEnvironment(.nothingPlaying)
        defer { environment.onboarding.cancel(); environment.player?.stop() }
        environment.showOnboarding()
        try #require(environment.onboarding.phase == .completing)
        for _ in 0..<3 { environment.showOnboarding() }
        try await liveLyricEventually { environment.onboarding.phase == .handoff }
        for _ in 0..<3 { environment.showOnboarding() }

        #expect(environment.requestedOnboardingSection == nil)
        try await liveLyricEventually { environment.onboarding.phase == .idle }
        #expect(environment.isShowingPlayer)
        #expect(environment.onboardingStep == nil)
    }

    @Test func openingLibraryConfigurationDoesNotDismissAnUnfinishedEdit() {
        let environment = makePreviewEnvironment(.nothingPlaying)
        defer { environment.onboarding.cancel(); environment.player?.stop() }
        environment.showOnboarding(section: .library)
        environment.updateOnboardingReadiness()

        #expect(environment.onboardingStep == .library(.idle))
        #expect(environment.requestedOnboardingSection == .library)
        #expect(environment.onboarding.phase == .idle && !environment.onboarding.isArmed)
        #expect(!environment.isShowingPlayer)
    }
}
