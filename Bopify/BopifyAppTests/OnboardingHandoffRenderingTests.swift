import AppKit
import CoreGraphics
import SwiftUI
import Testing
import BopifyAuth
import BopifyDomain
import BopifyPlayback

@MainActor @Suite("Onboarding native handoff", .serialized)
struct OnboardingHandoffRenderingTests {
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
        try fixture.capture("resized")
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

    @Test func libraryAndHelpFitWithoutScrollingInTheSameWindow() async throws {
        let fixture = try NativeOnboardingFixture(needsKey: false, section: .library)
        defer { fixture.close() }
        try await Task.sleep(for: .milliseconds(250))
        let content = try #require(fixture.panel.contentView)
        func expectInside(_ identifier: String) throws {
            let element = try AppearanceTestAccessibility.element(identifier, in: content)
            let screenFrame = try #require(element.object.accessibilityFrame?())
            let frame = content.convert(fixture.panel.convertFromScreen(screenFrame), from: nil)
            #expect(!frame.isEmpty && content.bounds.contains(frame))
        }
        try expectInside("onboarding.title")
        try expectInside("onboarding.libraryClientID")
        try expectInside("onboarding.saveLibrary")
        try fixture.capture("library")
        let help = try AppearanceTestAccessibility.element("onboarding.registrationHelp", in: content)
        #expect(help.press())
        try await Task.sleep(for: .milliseconds(250))
        try expectInside("onboarding.title")
        try expectInside("onboarding.openDashboard")
        try expectInside("onboarding.redirectURI")
        try expectInside("onboarding.registrationBack")
        #expect(!descendants(in: content).contains { $0 is NSScrollView })
        try fixture.capture("library-help")
    }

    @Test func nativeStartupKeepsTheFormVisibleAndAccessible() async throws {
        let fixture = try NativeOnboardingFixture(needsKey: true)
        defer { fixture.close() }
        try await Task.sleep(for: .milliseconds(220))
        fixture.panel.contentView?.layoutSubtreeIfNeeded()
        fixture.panel.makeKeyAndOrderFront(nil)
        try #require(fixture.panel.isKeyWindow)
        try fixture.capture("key-entry")
        let content = try #require(fixture.panel.contentView)
        let field = try #require(findSecureField(in: content))
        let frame = field.convert(field.bounds, to: content)
        #expect(frame.width > 100 && frame.height > 10)
        #expect(content.bounds.intersects(frame))
        _ = try AppearanceTestAccessibility.element("soloist.apiKey", in: content)
        _ = try AppearanceTestAccessibility.element("soloist.enable", in: content)
    }

    @Test func completionKeepsThePanelAndIdlePlaybackThroughTheHandoff() async throws {
        let fixture = try NativeOnboardingFixture(needsKey: false)
        defer { fixture.close() }
        try await liveLyricEventually { fixture.environment.onboardingRecordFrame?.width ?? 0 > 0 }
        let panel = fixture.panel
        let before = panel.windowNumber
        fixture.environment.onboarding.begin()
        fixture.environment.updateOnboardingReadiness(reduceMotion: false)
        #expect(fixture.environment.onboardingStep == .completion)
        // Allow the completion pose to settle, including setup that beats the initial record entrance.
        try await Task.sleep(for: .milliseconds(250))
        try fixture.capture("completion")
        let source = try #require(fixture.environment.onboardingRecordFrame)
        let anchor = CGPoint(x: panel.frame.minX + source.midX, y: panel.frame.maxY - source.midY)
        try await liveLyricEventually { fixture.environment.onboarding.phase == .handoff }
        try await Task.sleep(for: .milliseconds(300))
        try fixture.capture("handoff")
        try await liveLyricEventually {
            fixture.environment.onboarding.phase == .idle && !fixture.environment.playerWindowController.isTransitioning
        }
        try fixture.capture("player")
        #expect(panel.windowNumber == before && fixture.environment.isShowingPlayer)
        #expect(fixture.environment.player?.state.phase == .idle && fixture.environment.player?.state.currentTrack == nil)
        let layout = fixture.environment.playerWindowController.layout
        let final = CGPoint(x: panel.frame.minX + layout.recordCenter.x, y: panel.frame.maxY - layout.recordCenter.y)
        #expect(abs(final.x - anchor.x) < 2 && abs(final.y - anchor.y) < 2)
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
    private let artifacts: URL

    init(needsKey: Bool, section: OnboardingSection = .playback) throws {
        _ = NSApplication.shared
        saved = ["player.frame", "player.keepOnTop", "player.recordCenter"].map { ($0, UserDefaults.standard.object(forKey: $0)) }
        if needsKey {
            let suite = UserDefaults(suiteName: "native-onboarding-\(UUID())")!
            let soloist = SoloistPlaybackController(defaults: suite, keys: NativeOnboardingKeys(), authorize: {},
                install: { _, _ in throw SoloistPlaybackError.unavailable }, clearSession: {})
            environment = makePreviewEnvironment(.nothingPlaying, soloistController: soloist)
        } else {
            environment = makePreviewEnvironment(.nothingPlaying,
                libraryClientID: section == .library ? nil : String(repeating: "0", count: 32))
        }
        environment.showOnboarding(section: section)
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
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        artifacts = root.appendingPathComponent("build/test-artifacts/onboarding-composited/\(UUID())")
    }

    func capture(_ name: String) throws {
        if let token = ProcessInfo.processInfo.environment["BOPIFY_NATIVE_CAPTURE_TOKEN"],
           UUID(uuidString: token) != nil {
            try captureExternally(name, token: token)
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            print("Native onboarding composited capture unavailable: screen capture is not authorized")
            return
        }
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        let destination = artifacts.appendingPathComponent("\(name).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(panel.windowNumber), destination.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "Unable to capture the isolated native onboarding window")
        print("Native onboarding composited capture: \(destination.path)")
    }

    private func captureExternally(_ name: String, token: String) throws {
        let directory = artifacts.deletingLastPathComponent()
            .appendingPathComponent("capture-bridge/\(token)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        let requestID = UUID().uuidString
        let request = directory.appendingPathComponent("\(requestID).request.json")
        let response = directory.appendingPathComponent("\(requestID).response.json")
        let destination = artifacts.appendingPathComponent("\(name).png")
        let payload: [String: Any] = [
            "token": token, "requestID": requestID, "name": name,
            "processID": ProcessInfo.processInfo.processIdentifier,
            "windowNumber": panel.windowNumber, "destination": destination.path,
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: request, options: .atomic)
        defer {
            try? FileManager.default.removeItem(at: request)
            try? FileManager.default.removeItem(at: response)
        }
        // Hold the requested animation frame while the authorized tool process captures this window.
        let deadline = Date().addingTimeInterval(15)
        while !FileManager.default.fileExists(atPath: response.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.025)
        }
        try #require(FileManager.default.fileExists(atPath: response.path), "External native capture timed out")
        let result = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: response)) as? [String: Any])
        try #require(result["requestID"] as? String == requestID && result["token"] as? String == token)
        try #require(result["success"] as? Bool == true, "External capture failed: \(result["error"] ?? "unknown error")")
        try #require(FileManager.default.fileExists(atPath: destination.path))
        print("Native onboarding composited capture: \(destination.path)")
    }

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
