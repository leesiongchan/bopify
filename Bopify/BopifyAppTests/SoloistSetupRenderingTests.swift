import AppKit
import Network
import SwiftUI
import Testing
import BopifyDomain
import BopifyAuth
import BopifyPlayback

@MainActor @Suite("Soloist native presentation", .serialized)
struct SoloistSetupRenderingTests {
    @Test(arguments: [false, true])
    func initialBrowserReadinessRecoversOnlyAnAlreadyFailedSetup(alreadyFailed: Bool) async throws {
        _ = NSApplication.shared
        let suite = "soloist-rendering-mounted-recovery-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = LiveLyricTestEngine(), replacement = LiveLyricTestEngine()
        var starts = 0
        let controller = SoloistPlaybackController(defaults: defaults, keys: RenderingSetupKeys(), authorize: {},
            install: { _, _ in URL(fileURLWithPath: "/fixture/soloist") }, start: { request in
                starts += 1
                request.available(starts == 1 ? first : replacement)
                request.progress(alreadyFailed && starts == 1 ? .failed(.discoveryUnavailable) : .pairing(request.name))
                while true { try await Task.sleep(for: .milliseconds(10)) }
            }, clearSession: {})
        let environment = makePreviewEnvironment(.playing, soloistController: controller)
        let preparing = Task { await environment.enableSoloist(key: "fixture-key") }
        defer { preparing.cancel(); environment.player?.stop(); Task { await environment.cancelSoloistSetup() } }
        try await liveLyricEventually {
            if alreadyFailed { return controller.phase == .failed(.discovery) }
            if case .pairing = controller.phase { return true }; return false
        }
        var browserUpdates: [@MainActor (NWBrowser.State) -> Void] = []
        var recoveryEvents: [@MainActor (SoloistDiscovery.RecoveryEvent) -> Void] = []
        let discovery = SoloistDiscovery(makeBrowser: {
            SoloistDiscovery.Browser(start: { browserUpdates.append($0) }, cancel: {})
        }, observeRecovery: { recoveryEvents.append($0); return {} })
        let window = NSWindow(contentRect: CGRect(x: 300, y: 300, width: 410, height: 420),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: PlaybackOnboardingView(environment: environment, discovery: discovery)
            .frame(width: 410, height: 420))
        host.sizingOptions = []
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        try await liveLyricEventually { !browserUpdates.isEmpty }
        #expect(starts == 1, "Starting the observer is not proof that its browser is ready")
        browserUpdates[0](.ready)
        if alreadyFailed {
            try await liveLyricEventually { starts == 2 }
            #expect(first.shutdowns == 1)
        }
        try await Task.sleep(for: .milliseconds(100))
        browserUpdates.last?(.ready)
        recoveryEvents.last?(.activated)
        try await Task.sleep(for: .milliseconds(100))
        #expect(starts == (alreadyFailed ? 2 : 1), "Healthy pairing must retain its existing child")
        #expect(replacement.shutdowns == 0)
        await environment.cancelSoloistSetup()
        await preparing.value
    }

    @Test func startupSurfaceClipsOpaqueContentAtEveryCorner() throws {
        // Opaque content makes this a composition-mask test, independent of GPU glass/blur rendering.
        let renderer = ImageRenderer(content: StartupSurface(isAnimating: false) {
            Color.red.frame(width: 160, height: 180)
        }
        .frame(width: 160, height: 180)
        .padding(6))
        renderer.scale = 2
        let bitmap = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        let center = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2))
        #expect(center.alphaComponent > 0.99)
        for point in [(14, 14), (bitmap.pixelsWide - 15, 14),
                      (14, bitmap.pixelsHigh - 15), (bitmap.pixelsWide - 15, bitmap.pixelsHigh - 15)] {
            let corner = try #require(bitmap.colorAt(x: point.0, y: point.1))
            #expect(corner.alphaComponent < 0.01, "The complete startup composition must clip its opaque content")
        }
        let paddedOutside = try #require(bitmap.colorAt(x: 0, y: 0))
        #expect(paddedOutside.alphaComponent < 0.01)
    }

    @Test func headingsDescribeTheCurrentPlaybackStep() {
        #expect(PlaybackOnboardingCopy(phase: .idle).title == "onboarding.playbackTitle")
        #expect(PlaybackOnboardingCopy(phase: .pairing("Fixture device")).title == "onboarding.pairingTitle")
        #expect(PlaybackOnboardingCopy(phase: .installing(nil)).title == "onboarding.preparingTitle")
        #expect(PlaybackOnboardingCopy(phase: .failed(.startup)).title == "onboarding.attentionTitle")
        #expect(PlaybackOnboardingCopy(phase: .ready).title == "onboarding.readyTitle")
        #expect(PlaybackOnboardingCopy(phase: .limitedServices).title == "onboarding.readyTitle")
    }

    @Test func playbackScenesChangeOnlyAtMeaningfulBoundaries() {
        #expect(PlaybackOnboardingScene(phase: .idle) == PlaybackOnboardingScene(phase: .failed(.invalidKey)))
        #expect(PlaybackOnboardingScene(phase: .installing(nil)) == PlaybackOnboardingScene(phase: .installing(0.6)))
        #expect(PlaybackOnboardingScene(phase: .authorizing) == PlaybackOnboardingScene(phase: .checkingAccount))
        #expect(PlaybackOnboardingScene(phase: .installing(0.9)) != PlaybackOnboardingScene(phase: .pairing("Fixture")))
        #expect(PlaybackOnboardingScene(phase: .pairing("Fixture")) == PlaybackOnboardingScene(phase: .failed(.discovery)))
        #expect(PlaybackOnboardingScene(phase: .pairing("Fixture")) != PlaybackOnboardingScene(phase: .verifying))
        #expect(PlaybackOnboardingCopy(phase: .verifying).title == "onboarding.connectingTitle")
    }

    @Test func deniedLocalNetworkAccessOffersContextualSettings() async throws {
        _ = NSApplication.shared
        var openedSettings = false
        let view = SoloistPairingGuidance(state: .denied,
            openSettings: { openedSettings = true }, openSpotify: {})
        let window = NSWindow(contentRect: CGRect(x: 300, y: 300, width: 410, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: view.frame(width: 410, height: 300)
            .environment(\.accessibilityEnabled, true))
        host.sizingOptions = []
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(150))
        let settings = try AppearanceTestAccessibility.element("soloist.localNetworkSettings", in: host)
        #expect(settings.object.accessibilityRole?() == .button)
        #expect(settings.press() && openedSettings)
        _ = try AppearanceTestAccessibility.element("soloist.discoveryDenied", in: host)
        #expect(!hasAccessibilityElement("soloist.retryDiscovery", in: host))
        #expect(!hasAccessibilityElement("soloist.openSpotify", in: host))
        let artifacts = try captureDirectory()
        try capture(host, at: artifacts.appendingPathComponent("local-network-denied.png"))
        print("Local network guidance capture: \(artifacts.path)")
    }

    @Test(arguments: [SoloistDiscovery.State.idle, .browsing])
    func ordinaryDiscoveryKeepsPairingInstructions(state: SoloistDiscovery.State) async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 300, y: 300, width: 410, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: SoloistPairingGuidance(state: state,
            openSettings: {}, openSpotify: {}).frame(width: 410, height: 300)
            .environment(\.accessibilityEnabled, true))
        host.sizingOptions = []
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(150))
        _ = try AppearanceTestAccessibility.element("soloist.pairingHelp", in: host)
        _ = try AppearanceTestAccessibility.element("soloist.openSpotify", in: host)
    }

    @Test func unavailableDiscoveryWaitsWithoutAManualRestart() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 300, y: 300, width: 410, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: SoloistPairingGuidance(state: .unavailable,
            openSettings: {}, openSpotify: {}).frame(width: 410, height: 300)
            .environment(\.accessibilityEnabled, true))
        host.sizingOptions = []
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(150))
        _ = try AppearanceTestAccessibility.element("soloist.discoveryUnavailable", in: host)
        _ = try AppearanceTestAccessibility.element("soloist.openSpotify", in: host)
        #expect(!hasAccessibilityElement("soloist.retryDiscovery", in: host))
        #expect(!hasAccessibilityElement("soloist.localNetworkSettings", in: host))
    }

    @Test(arguments: [false, true])
    func failedDiscoveryDoesNotAdvertiseADeviceBeforeItRecovers(isRecovering: Bool) async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 300, y: 300, width: 410, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: SoloistPairingGuidance(state: .browsing, isConnectionUnavailable: true,
            isRecovering: isRecovering, openSettings: {}, openSpotify: {}).frame(width: 410, height: 300)
            .environment(\.accessibilityEnabled, true))
        host.sizingOptions = []
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(150))
        _ = try AppearanceTestAccessibility.element(isRecovering ? "soloist.discoveryRecovering" : "soloist.connectionUnavailable", in: host)
        #expect(!hasAccessibilityElement("soloist.pairingHelp", in: host))
        #expect(!hasAccessibilityElement("soloist.openSpotify", in: host))
        #expect(!hasAccessibilityElement("soloist.localNetworkSettings", in: host))
    }

    @Test(arguments: [(true, false), (false, true)])
    func accessibilitySettingsGiveInputsOpaqueBacking(reduceTransparency: Bool, increasedContrast: Bool) throws {
        let renderer = ImageRenderer(content: StartupInputBackground(reduceTransparency: reduceTransparency,
            increasedContrast: increasedContrast).frame(width: 100, height: 44).padding(4))
        renderer.scale = 2
        let bitmap = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        let center = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2))
        let outside = try #require(bitmap.colorAt(x: 0, y: 0))
        #expect(center.alphaComponent > 0.99)
        #expect(outside.alphaComponent < 0.01)
    }

    @Test func smallHighContrastSetupKeepsAccessibleNamesAndSecureKeyboardEntry() async throws {
        _ = NSApplication.shared
        let environment = makeKeyEntryEnvironment()
        environment.showOnboarding(section: .playback)
        let window = NSWindow(contentRect: CGRect(x: 300, y: 300, width: 320, height: 480),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .accessibilityHighContrastDarkAqua)
        defer { window.close(); environment.player?.stop() }
        let host = NSHostingView(rootView: PlayerRootView(environment: environment)
            .frame(width: 320, height: 480)
            .dynamicTypeSize(.accessibility2)
            .environment(\.accessibilityEnabled, true))
        host.sizingOptions = []
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(180))
        let field = try #require(secureField(in: host))
        let cell = try #require(field.cell as? NSSecureTextFieldCell)
        #expect(cell.echosBullets && cell.accessibilitySubrole() == .secureTextField)
        #expect(!field.isBezeled, "The native field must not stack its old bezel over the glass control")
        #expect((field.font?.pointSize ?? 0) >= 13)
        let accessibleKey = try AppearanceTestAccessibility.element("soloist.apiKey", in: host)
        #expect(accessibleKey.object.accessibilityRole?() == .textField)
        #expect(accessibleKey.object.accessibilityLabel?() == SoloistResources.string("soloist.key"))
        #expect(!hasAccessibilityElement("soloist.keyLabel", in: host))
        let step = try AppearanceTestAccessibility.element("onboarding.step", in: host)
        #expect(step.object.accessibilityRole?() == .staticText)
        field.selectText(nil)
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.insertText("fixture-key", replacementRange: editor.selectedRange())
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        editor.insertTab(nil)
        try await Task.sleep(for: .milliseconds(80))
        #expect(environment.soloist.phase == .idle, "Tab must not submit playback setup")
        #expect(secureField(in: host) === field && field.stringValue == "fixture-key")
        field.selectText(nil)
        #expect(field.currentEditor() != nil)
        #expect(scrollView(in: host) == nil)
        try expectVisible("onboarding.title", in: host)
        try expectVisible("soloist.apiKey", in: host)
        try expectVisible("soloist.enable", in: host)
        let artifacts = try captureDirectory()
        try capture(host, at: artifacts.appendingPathComponent("high-contrast-key.png"))
        print("Readable onboarding capture: \(artifacts.path)")
    }

    @Test(arguments: [false, true])
    func onboardingRemainsReadableInLightAndDarkLayouts(dark: Bool) async throws {
        _ = NSApplication.shared
        let artifacts = try captureDirectory()
        for compact in [false, true] {
            for library in [false, true] {
                let width: CGFloat = compact ? 320 : 410
                let height: CGFloat = compact ? 480 : 700
                let environment = library ? makePreviewEnvironment(.playing, libraryClientID: nil) : makeKeyEntryEnvironment()
                environment.showOnboarding(section: library ? .library : .playback)
                let window = NSWindow(contentRect: CGRect(x: 300, y: 300, width: width, height: height),
                    styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark
                    ? compact ? .accessibilityHighContrastDarkAqua : .darkAqua
                    : compact ? .accessibilityHighContrastAqua : .aqua)
                defer { window.close(); environment.player?.stop() }
                let host = NSHostingView(rootView: PlayerRootView(environment: environment)
                    .frame(width: width, height: height)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .environment(\.accessibilityEnabled, true))
                host.sizingOptions = []
                window.contentView = host
                window.makeKeyAndOrderFront(nil)
                try await Task.sleep(for: .milliseconds(120))
                let stem = "\(dark ? "dark" : "light")-\(compact ? "compact-high-contrast" : "regular")-\(library ? "library" : "key")"
                #expect(scrollView(in: host) == nil)
                _ = try AppearanceTestAccessibility.element("onboarding.step", in: host)
                let input = try AppearanceTestAccessibility.element(library ? "onboarding.libraryClientID" : "soloist.apiKey", in: host)
                #expect(input.object.accessibilityRole?() == .textField)
                #expect(input.object.accessibilityLabel?() == SoloistResources.string(library ? "librarySetup.clientID" : "soloist.key"))
                try expectVisible("onboarding.title", in: host)
                try expectVisible(library ? "onboarding.libraryClientID" : "soloist.apiKey", in: host)
                try expectVisible(library ? "onboarding.saveLibrary" : "soloist.enable", in: host)
                try capture(host, at: artifacts.appendingPathComponent(stem + ".png"))
            }
        }
        print("Onboarding light/dark capture matrix: \(artifacts.path)")
    }

    @Test func keyEntryIsSecureAndKeyboardSetupFailureKeepsThePlayerAndOffersRetry() async throws {
        _ = NSApplication.shared
        let environment = makeKeyEntryEnvironment()
        let originalTrack = environment.player?.state.currentTrack
        environment.showOnboarding(section: .playback)
        let window = NSWindow(contentRect: CGRect(x: 300, y: 300, width: 410, height: 700),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); environment.player?.stop() }
        let host = NSHostingView(rootView: PlayerRootView(environment: environment)
            .frame(width: 410, height: 700)
            .environment(\.accessibilityEnabled, true))
        host.sizingOptions = []
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        let content = try #require(window.contentView)
        try await Task.sleep(for: .milliseconds(150))
        let field = try #require(secureField(in: content))
        let cell = try #require(field.cell as? NSSecureTextFieldCell)
        #expect(cell.echosBullets)
        #expect(cell.accessibilitySubrole() == .secureTextField)
        #expect(cell.accessibilityPlaceholderValue() == SoloistResources.string("soloist.keyPlaceholder"))
        #expect(field.isEditable)
        let artifacts = try captureDirectory()
        try capture(content, at: artifacts.appendingPathComponent("initial.png"))
        print("Soloist initial capture: \(artifacts.path)")
        let enable = try AppearanceTestAccessibility.element("soloist.enable", in: content)
        #expect(enable.object.accessibilityRole?() == .button)
        field.selectText(nil)
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.insertText("fixture-key", replacementRange: editor.selectedRange())
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        try await Task.sleep(for: .milliseconds(80))
        #expect(field.stringValue == "fixture-key")
        #expect(window.firstResponder === editor)
        let updatedEnable = try AppearanceTestAccessibility.element("soloist.enable", in: content)
        #expect(updatedEnable.object.accessibilityRole?() == .button)
        editor.insertNewline(nil)
        try await liveLyricEventually {
            if case .failed = environment.soloist.phase { return true }; return false
        }
        #expect(!hasAccessibilityElement("soloist.cancelSetup", in: content))
        #expect(!hasAccessibilityElement("onboarding.library", in: content))
        try await liveLyricEventually { hasAccessibilityElement("soloist.enable", in: content) }
        _ = try AppearanceTestAccessibility.element("soloist.enable", in: content)
        try await liveLyricEventually { hasAccessibilityElement("soloist.apiKey", in: content) }
        let retryField = try #require(secureField(in: content))
        let retryCell = try #require(retryField.cell as? NSSecureTextFieldCell)
        #expect(retryCell.echosBullets && retryCell.accessibilityLabel() == SoloistResources.string("soloist.key"))
        #expect(environment.isShowingOnboarding)
        #expect(environment.playerMode == .expanded)
        #expect(environment.player?.state.currentTrack == originalTrack)
        #expect(!environment.soloist.hasUsablePlayback)
        content.layoutSubtreeIfNeeded()
        try capture(content, at: artifacts.appendingPathComponent("retry.png"))
        print("Soloist UI captures: \(artifacts.path)")
    }

    private func makeKeyEntryEnvironment() -> AppEnvironment {
        let defaults = UserDefaults(suiteName: "soloist-rendering-\(UUID())")!
        let controller = SoloistPlaybackController(defaults: defaults, keys: RenderingSetupKeys(), authorize: {},
            install: { _, _ in throw SoloistPlaybackError.unavailable }, clearSession: {})
        return makePreviewEnvironment(.playing, soloistController: controller)
    }

    private func hasAccessibilityElement(_ identifier: String, in root: Any) -> Bool {
        var visited = Set<ObjectIdentifier>()
        func contains(_ object: Any) -> Bool {
            let node = object as AnyObject
            guard visited.insert(ObjectIdentifier(node)).inserted else { return false }
            if node.accessibilityIdentifier?() == identifier { return true }
            let children = (node.accessibilityChildren?() ?? []) + (node.accessibilityContents?() ?? [])
            if children.contains(where: contains) { return true }
            return (object as? NSView)?.subviews.contains(where: contains) ?? false
        }
        return contains(root)
    }

    private func expectVisible(_ identifier: String, in host: NSView) throws {
        let element = try AppearanceTestAccessibility.element(identifier, in: host)
        let screenFrame = try #require(element.object.accessibilityFrame?())
        let window = try #require(host.window)
        let frame = host.convert(window.convertFromScreen(screenFrame), from: nil)
        #expect(!frame.isEmpty && host.bounds.insetBy(dx: -1, dy: -1).contains(frame),
                "The entire control must fit without scrolling")
    }

    private func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
    }

    private func secureField(in view: NSView) -> NSSecureTextField? {
        if let field = view as? NSSecureTextField { return field }
        return view.subviews.lazy.compactMap { secureField(in: $0) }.first
    }

    private func captureDirectory() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let destination = root.appendingPathComponent("build/test-artifacts/onboarding/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        return destination
    }

    private func capture(_ view: NSView, at destination: URL) throws {
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: destination, options: .withoutOverwriting)
    }
}

private nonisolated final class RenderingSetupKeys: SoloistKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func load() throws -> String? { lock.withLock { value } }
    func save(_ key: String) throws { lock.withLock { value = key } }
    func clear() throws { lock.withLock { value = nil } }
}
