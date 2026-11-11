import AppKit
import CoreGraphics
import SwiftUI
import Testing
import BopifyAuth
import BopifyDomain
import BopifyPlayback

@MainActor @Suite("Onboarding native handoff", .serialized)
struct OnboardingHandoffRenderingTests {
    @Test func theActualPlayerHandoffRendersIntermediateRecordSizes() async throws {
        let fixture = try NativeOnboardingFixture(needsKey: false)
        defer { fixture.close() }
        fixture.environment.onboarding.begin()
        try await liveLyricEventually { fixture.environment.playerWindowController.onboardingHandoff != nil }
        let transfer = try #require(fixture.environment.playerWindowController.onboardingHandoff)
        var widths: [CGFloat] = []
        let began = Date()
        var trace: [(Int, Int)] = []
        let deadline = Date().addingTimeInterval(2)
        while fixture.environment.playerWindowController.onboardingHandoff != nil, Date() < deadline {
            if let width = fixture.environment.onboardingRecordFrame?.width {
                widths.append(width)
                if trace.last?.1 != Int(width) { trace.append((Int(Date().timeIntervalSince(began) * 1000), Int(width))) }
            }
            try await Task.sleep(for: .milliseconds(8))
        }
        let intermediate = widths.filter { $0 > transfer.source.width + 4 && $0 < transfer.destination.width - 4 }
        print("Rendered handoff milliseconds/record width: \(trace)")
        let movingFrames = trace.filter { CGFloat($0.1) > transfer.source.width + 4 && CGFloat($0.1) < transfer.destination.width - 4 }
        let movingDuration = (movingFrames.last?.0 ?? 0) - (movingFrames.first?.0 ?? 0)
        #expect(movingDuration >= 250,
                "Visible motion must occupy the handoff, rather than be compressed into a brief snap followed by a stationary wait")
        #expect(Set(intermediate.map { Int($0) }).count >= 3,
                "The native player must present multiple intermediate record sizes, rather than jump to its final size")
    }

    @Test func dismissingTheActualPanelSettlesTheNativeHandoffBounds() async throws {
        let fixture = try NativeOnboardingFixture(needsKey: false)
        defer { fixture.close() }
        fixture.environment.onboarding.begin()
        try await liveLyricEventually { fixture.environment.playerWindowController.onboardingHandoff != nil }
        try #require(fixture.environment.onboarding.phase == .handoff)
        fixture.dismiss()
        #expect(!fixture.panel.isVisible)
        #expect(fixture.environment.playerWindowController.contentOffset == .zero)
        #expect(fixture.panel.frame.size == fixture.environment.playerWindowController.layout.contentSize)
        #expect(fixture.environment.playerWindowController.onboardingHandoff == nil)
    }

    @Test func resizedStartupKeepsHeaderAndFormInsideTheNativeViewportWithoutScrolling() async throws {
        let fixture = try NativeOnboardingFixture(needsKey: true)
        defer { fixture.close() }
        try await Task.sleep(for: .milliseconds(220))
        let panel = fixture.panel
        panel.maxSize = CGSize(width: 10_000, height: 10_000)
        panel.setFrame(CGRect(x: 180, y: 80, width: 500, height: 700), display: true)
        try await Task.sleep(for: .milliseconds(100))
        panel.setFrame(CGRect(x: 180, y: 80, width: 430, height: 660), display: true)
        try await Task.sleep(for: .milliseconds(100))
        let content = try #require(panel.contentView)
        content.layoutSubtreeIfNeeded()
        #expect(content.bounds.size == CGSize(width: 430, height: 660))
        let progress = try AppearanceTestAccessibility.element("onboarding.step", in: content)
        let progressOnScreen = try #require(progress.object.accessibilityFrame?())
        let progressInWindow = panel.convertFromScreen(progressOnScreen)
        let progressInContent = content.convert(progressInWindow, from: nil)
        #expect(!progressInContent.isEmpty)
        #expect(content.bounds.contains(progressInContent), "The header must follow the native viewport after it shrinks")
        let forms = descendants(in: content).compactMap { $0 as? NSHostingView<AnyView> }
        #expect(!forms.isEmpty)
        for form in forms {
            #expect(content.bounds.contains(form.convert(form.bounds, to: content)),
                    "The form host must not retain the previous wider startup bounds")
        }
        #expect(!descendants(in: content).contains { $0 is NSScrollView },
                "Every onboarding step must fit without a scrolling form")
        let field = try #require(findSecureField(in: content))
        #expect(content.bounds.contains(field.convert(field.bounds, to: content)))
    }

    private func findSecureField(in view: NSView) -> NSSecureTextField? {
        if let field = view as? NSSecureTextField { return field }
        return view.subviews.lazy.compactMap { findSecureField(in: $0) }.first
    }

    private func descendants(in view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(in: $0) }
    }
}

@MainActor
private final class NativeOnboardingFixture {
    let environment: AppEnvironment
    let panel: StatusPanel
    private let controller: StatusItemController
    private let background: NSWindow
    private let saved: [(String, Any?)]

    init(needsKey: Bool) throws {
        _ = NSApplication.shared
        saved = ["player.frame", "player.keepOnTop", "player.recordCenter"].map { ($0, UserDefaults.standard.object(forKey: $0)) }
        if needsKey {
            let suite = UserDefaults(suiteName: "native-onboarding-\(UUID())")!
            let soloist = SoloistPlaybackController(defaults: suite, keys: NativeOnboardingKeys(), authorize: {},
                install: { _, _ in throw SoloistPlaybackError.unavailable }, clearSession: {})
            environment = makePreviewEnvironment(.nothingPlaying, soloistController: soloist)
        } else {
            environment = makePreviewEnvironment(.nothingPlaying,
                libraryClientID: String(repeating: "0", count: 32))
        }
        environment.showOnboarding(section: .playback)
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        controller = StatusItemController(
            content: PlayerRootView(environment: environment).environment(\.accessibilityEnabled, true),
            environment: environment)
        panel = try #require(NSApp.windows.compactMap { $0 as? StatusPanel }
            .first { !existing.contains(ObjectIdentifier($0)) })
        panel.isReleasedWhenClosed = false
        panel.setFrame(CGRect(x: 180, y: 80, width: 410, height: 680), display: false)
        background = NSWindow(contentRect: panel.frame.insetBy(dx: -30, dy: -30),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        background.isReleasedWhenClosed = false
        background.backgroundColor = NSColor(calibratedRed: 0.30, green: 0.34, blue: 0.32, alpha: 1)
        background.isOpaque = true
        background.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
    }

    func dismiss() { controller.togglePlayer() }

    func close() {
        environment.onboarding.cancel()
        environment.player?.stop()
        withExtendedLifetime(controller) { panel.close() }
        background.close()
        for (key, value) in saved {
            if let value { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }
}

private nonisolated final class NativeOnboardingKeys: SoloistKeyStoring, @unchecked Sendable {
    func load() throws -> String? { nil }
    func save(_ key: String) throws {}
    func clear() throws {}
}
