import AppKit
import SwiftUI
import Testing
import BopifyPlayback
import BopifyAuth
import BopifyDomain

@MainActor @Suite("Startup native sizing", .serialized)
struct StartupNativeSizingTests {
    @Test(arguments: [false, true])
    func theFirstFrameUsesTheRealFormBeforeItBecomesVisible(library: Bool) async throws {
        _ = NSApplication.shared
        let saved = ["player.frame", "player.keepOnTop", "player.recordCenter"].map {
            ($0, UserDefaults.standard.object(forKey: $0))
        }
        defer {
            for (key, value) in saved {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        // The fresh host starts at 410pt; a restored wider frame must not reuse that provisional measurement.
        UserDefaults.standard.set(NSStringFromRect(CGRect(x: 40, y: 40, width: 430, height: 600)), forKey: "player.frame")
        let environment: AppEnvironment
        if library {
            environment = makePreviewEnvironment(.nothingPlaying, libraryClientID: nil)
            environment.showOnboarding(section: .library)
        } else {
            environment = AppEnvironment(previewPlayer: nil, favoriteService: InitialSizingLibrary(),
                playbackAuth: SpotifyAuthService(clientID: "fixture", store: InitialSizingTokens()),
                libraryAuth: SpotifyAuthService(clientID: "fixture", store: InitialSizingTokens()))
            await environment.signOut()
            try #require(environment.onboardingStep == .signIn(.idle))
        }
        defer { environment.onboarding.cancel(); environment.startupWindow.cancelPendingResize(); environment.player?.stop() }
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        let controller = StatusItemController(content: PlayerRootView(environment: environment), environment: environment)
        let panel = try #require(NSApp.windows.compactMap { $0 as? StatusPanel }
            .first { !existing.contains(ObjectIdentifier($0)) })
        panel.isReleasedWhenClosed = false
        defer { withExtendedLifetime(controller) { panel.close() } }
        let width = panel.frame.width
        let form: AnyView = if library {
            AnyView(LibraryAuthorizationSetupView(status: .idle, environment: environment))
        } else {
            AnyView(SignInView(status: .idle, onSignIn: {}))
        }
        let measurer = NSHostingController(rootView: form.fixedSize(horizontal: false, vertical: true)
            .frame(width: width - 32))
        let formHeight = measurer.sizeThatFits(in: CGSize(width: width - 32, height: .greatestFiniteMagnitude)).height
        #expect(!panel.isVisible)
        let initialHeight = panel.frame.height
        let measuredHeight = 82 + 324 * environment.startupWindow.recordScale + formHeight
        #expect(abs(initialHeight - measuredHeight) <= 1,
                "The hidden panel must use current content measured at its final width")
        if library { #expect(environment.startupWindow.recordScale <= 0.55) }
        controller.showPlayer()
        #expect(panel.frame.height == initialHeight)
        try await Task.sleep(for: .milliseconds(500))
        #expect(panel.frame.height == initialHeight,
                "The first visible frame must not be corrected by a later geometry callback")
    }

    @Test func theFirstLibraryTargetIsReadyBeforeMountedGeometryArrives() throws {
        _ = NSApplication.shared
        let environment = makePreviewEnvironment(.nothingPlaying, libraryClientID: nil)
        defer { environment.startupWindow.cancelPendingResize(); environment.player?.stop() }
        environment.startupWindow.useScreen(height: 900)
        environment.startupWindow.measure(contentHeight: 200)
        environment.showOnboarding(section: .library)
        let root = PlayerRootView(environment: environment)
        #expect(root.prepareStartupSizing(for: .library(.idle), width: 430, immediately: false))
        let measurer = NSHostingController(rootView: LibraryAuthorizationSetupView(status: .idle, environment: environment)
            .fixedSize(horizontal: false, vertical: true).frame(width: 398))
        let formHeight = measurer.sizeThatFits(in: CGSize(width: 398, height: CGFloat.greatestFiniteMagnitude)).height
        let expected = ceil(82 + 324 * environment.startupWindow.recordScale + formHeight)
        #expect(environment.startupWindow.height == expected)
        #expect(environment.startupWindow.recordScale == 0.55)
        let key = root.startupMeasurementKey(for: .library(.idle), width: 430)
        #expect(environment.startupWindow.measuredHeight(for: key) == formHeight)
    }

    @Test func changingContentInTheSameModeKeepsTheTopEdgeAndRecordScale() async throws {
        _ = NSApplication.shared
        let saved = ["player.frame", "player.keepOnTop", "player.recordCenter"].map {
            ($0, UserDefaults.standard.object(forKey: $0))
        }
        defer {
            for (key, value) in saved {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        let environment = makePreviewEnvironment(.nothingPlaying)
        defer { environment.onboarding.cancel(); environment.startupWindow.cancelPendingResize(); environment.player?.stop() }
        environment.showOnboarding(section: .library)
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        let controller = StatusItemController(content: EmptyView(), environment: environment)
        let panel = try #require(NSApp.windows.compactMap { $0 as? StatusPanel }
            .first { !existing.contains(ObjectIdentifier($0)) })
        panel.isReleasedWhenClosed = false
        defer { withExtendedLifetime(controller) { panel.close() } }
        let visible = try #require(panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame)
        panel.setFrame(CGRect(x: visible.minX + 40, y: visible.maxY - 450, width: 410, height: 450), display: false)
        let top = panel.frame.maxY
        let scale = environment.startupWindow.recordScale

        environment.startupWindow.measure(contentHeight: 200)
        try await Task.sleep(for: .milliseconds(60))
        let first = panel.frame.height
        #expect(first == environment.startupWindow.height)
        environment.startupWindow.measure(contentHeight: 300)
        try await Task.sleep(for: .milliseconds(60))
        #expect(panel.frame.height > first)
        #expect(panel.frame.height == environment.startupWindow.height)
        #expect(abs(panel.frame.maxY - top) < 0.5)
        #expect(environment.startupWindow.recordScale == scale)
        #expect(environment.isShowingOnboarding)
    }
}

private struct InitialSizingTokens: TokenStoring {
    func load() throws -> TokenSet? { nil }
    func save(_ tokens: TokenSet) throws {}
    func clear() throws {}
}

private struct InitialSizingLibrary: LibraryService {
    func savedState(for uri: SpotifyURI) async throws -> Bool { false }
    func save(_ uri: SpotifyURI) async throws {}
    func remove(_ uri: SpotifyURI) async throws {}
}
