import AppKit
import SwiftUI
import Testing
import BopifyPlayback

@MainActor @Suite("Unfocused onboarding handoff", .serialized)
struct OnboardingUnfocusedHandoffTests {
    @Test func browserReturnRevealsThePlayerWithoutTakingKeyboardFocus() async throws {
        _ = NSApplication.shared
        let saved = ["player.frame", "player.keepOnTop", "player.recordCenter"].map {
            ($0, UserDefaults.standard.object(forKey: $0))
        }
        UserDefaults.standard.set(false, forKey: "player.keepOnTop")
        let environment = makePreviewEnvironment(.nothingPlaying, libraryClientID: String(repeating: "0", count: 32))
        environment.showOnboarding(section: .playback)
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        let controller = StatusItemController(content: PlayerRootView(environment: environment), environment: environment)
        let panel = try #require(NSApp.windows.compactMap { $0 as? StatusPanel }
            .first { !existing.contains(ObjectIdentifier($0)) })
        panel.isReleasedWhenClosed = false
        let browser = NSWindow(contentRect: CGRect(x: 100, y: 40, width: 900, height: 800),
                               styleMask: [.titled], backing: .buffered, defer: false)
        browser.isReleasedWhenClosed = false
        defer {
            environment.onboarding.cancel()
            environment.player?.stop()
            withExtendedLifetime(controller) { panel.close() }
            browser.close()
            for (key, value) in saved {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        panel.setFrame(CGRect(x: 180, y: 80, width: 410, height: 680), display: false)
        panel.orderFrontRegardless()
        browser.orderFrontRegardless()
        try #require(panel.isVisible && !panel.isKeyWindow)
        try #require(panel.level == .floating)
        environment.presentation.sendAttention(.visibility(true))
        environment.presentation.sendAttention(.pointer(false))
        environment.presentation.sendAttention(.keyboardFocus(false))
        environment.onboarding.begin()
        try await liveLyricEventually { environment.playerWindowController.onboardingHandoff != nil }
        let transfer = try #require(environment.playerWindowController.onboardingHandoff)
        let began = Date()
        #expect(!panel.isKeyWindow)
        #expect(environment.presentation.mode == .expanded)
        #expect(transfer.destination.width == 182)
        #expect(!environment.playerWindowController.layout.controlsFrame.isEmpty)
        #expect(environment.playerWindowController.isTransitioning)
        var widths: [CGFloat] = []
        while environment.playerWindowController.onboardingHandoff != nil, Date().timeIntervalSince(began) < 2 {
            if let width = environment.onboardingRecordFrame?.width { widths.append(width) }
            try await Task.sleep(for: .milliseconds(8))
        }
        let elapsed = Date().timeIntervalSince(began)
        print("Unfocused handoff source=\(transfer.source.width) destination=\(transfer.destination.width) elapsed=\(elapsed) range=\(widths.min() ?? 0)...\(widths.max() ?? 0)")
        #expect(elapsed >= 0.4, "An unfocused visible panel must not settle immediately")
        #expect(environment.onboarding.phase == .idle)
        #expect(environment.playerWindowController.onboardingHandoff == nil)
        try await liveLyricEventually { !environment.playerWindowController.isTransitioning }
        #expect(!panel.isKeyWindow)
        try await Task.sleep(for: .milliseconds(700))
        #expect(panel.level == .normal && !panel.isKeyWindow)
        #expect(environment.presentation.mode == .expanded && !environment.playerWindowController.layout.controlsFrame.isEmpty,
                "The player must remain visible after setup, rather than collapsing before its first interaction")
        let windows = try #require(CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]])
        let numbers = windows.compactMap { $0[kCGWindowNumber as String] as? Int }
        let playerOrder = try #require(numbers.firstIndex(of: panel.windowNumber))
        let browserOrder = try #require(numbers.firstIndex(of: browser.windowNumber))
        #expect(playerOrder < browserOrder,
                "Returning the player to normal window level must not bury it behind the authorization browser")
        panel.onPointerChanged?(true)
        panel.onPointerChanged?(false)
        try await liveLyricEventually { environment.presentation.mode == .compact }
        panel.cancelOperation(nil)
        try await liveLyricEventually { !environment.presentation.isVisible && environment.presentation.mode == .compact }
    }
}
