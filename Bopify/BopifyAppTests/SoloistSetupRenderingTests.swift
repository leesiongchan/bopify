import AppKit
import SwiftUI
import Testing
import BopifyDomain
import BopifyPlayback

@MainActor @Suite("Soloist native presentation", .serialized)
struct SoloistSetupRenderingTests {
    @Test func headingsDescribeTheCurrentPlaybackStep() {
        #expect(PlaybackOnboardingCopy(phase: .idle).title == "onboarding.playbackTitle")
        #expect(PlaybackOnboardingCopy(phase: .pairing("Fixture device")).title == "onboarding.pairingTitle")
        #expect(PlaybackOnboardingCopy(phase: .installing(nil)).title == "onboarding.preparingTitle")
        #expect(PlaybackOnboardingCopy(phase: .failed(.startup)).title == "onboarding.attentionTitle")
        #expect(PlaybackOnboardingCopy(phase: .ready).title == "onboarding.readyTitle")
        #expect(PlaybackOnboardingCopy(phase: .limitedServices).title == "onboarding.readyTitle")
    }

    @Test func deniedLocalNetworkAccessOffersSettingsAndTheDesktopApp() async throws {
        _ = NSApplication.shared
        var openedSettings = false
        var openedSpotify = false
        var retried = false
        let view = SoloistPairingGuidance(state: .denied,
            openSettings: { openedSettings = true }, openSpotify: { openedSpotify = true }, onRetry: { retried = true })
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
        let spotify = try AppearanceTestAccessibility.element("soloist.openSpotify", in: host)
        #expect(spotify.object.accessibilityRole?() == .button)
        #expect(spotify.press() && openedSpotify)
        _ = try AppearanceTestAccessibility.element("soloist.discoveryDenied", in: host)
        let retry = try AppearanceTestAccessibility.element("soloist.retryDiscovery", in: host)
        #expect(retry.press() && retried)
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
            openSettings: {}, openSpotify: {}, onRetry: {}).frame(width: 410, height: 300)
            .environment(\.accessibilityEnabled, true))
        host.sizingOptions = []
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(150))
        _ = try AppearanceTestAccessibility.element("soloist.pairingHelp", in: host)
        _ = try AppearanceTestAccessibility.element("soloist.openSpotify", in: host)
    }

    @Test(arguments: [false, true])
    func unavailableDiscoveryExplainsHowToRetry(isRetrying: Bool) async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 300, y: 300, width: 410, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: SoloistPairingGuidance(state: .unavailable, isRetrying: isRetrying,
            openSettings: {}, openSpotify: {}, onRetry: {}).frame(width: 410, height: 300)
            .environment(\.accessibilityEnabled, true))
        host.sizingOptions = []
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(150))
        _ = try AppearanceTestAccessibility.element("soloist.discoveryUnavailable", in: host)
        _ = try AppearanceTestAccessibility.element("soloist.openSpotify", in: host)
        let retry = try AppearanceTestAccessibility.element("soloist.retryDiscovery", in: host)
        #expect(retry.object.isAccessibilityEnabled?() == !isRetrying)
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

    @Test func smallHighContrastSetupKeepsLabelsAndSecureKeyboardEntry() async throws {
        _ = NSApplication.shared
        let environment = makePreviewEnvironment(.playing)
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
        _ = try AppearanceTestAccessibility.element("soloist.keyLabel", in: host)
        let step = try AppearanceTestAccessibility.element("onboarding.step", in: host)
        #expect(step.object.accessibilityRole?() == .staticText)
        field.selectText(nil)
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.insertText("fixture-key", replacementRange: editor.selectedRange())
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        editor.insertTab(nil)
        try await Task.sleep(for: .milliseconds(80))
        #expect(environment.soloist.hasUsablePlayback, "Tab must not submit playback setup")
        #expect(secureField(in: host) === field && field.stringValue == "fixture-key")
        field.selectText(nil)
        #expect(field.currentEditor() != nil)
        let scroll = try #require(scrollView(in: host))
        let document = try #require(scroll.documentView)
        #expect(document.frame.width <= scroll.contentView.bounds.width + 1)
        document.scroll(NSPoint(x: 0, y: max(0, document.frame.height - scroll.contentView.bounds.height)))
        scroll.reflectScrolledClipView(scroll.contentView)
        _ = try AppearanceTestAccessibility.element("soloist.enable", in: host)
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
                let environment = makePreviewEnvironment(.playing, libraryClientID: library ? nil : String(repeating: "0", count: 32))
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
                let scroll = try #require(scrollView(in: host))
                let document = try #require(scroll.documentView)
                #expect(document.frame.width <= scroll.contentView.bounds.width + 1)
                _ = try AppearanceTestAccessibility.element("onboarding.step", in: host)
                _ = try AppearanceTestAccessibility.element(library ? "onboarding.clientIDLabel" : "soloist.keyLabel", in: host)
                document.scroll(.zero)
                scroll.reflectScrolledClipView(scroll.contentView)
                try capture(host, at: artifacts.appendingPathComponent(stem + "-top.png"))
                document.scroll(NSPoint(x: 0, y: max(0, document.frame.height - scroll.contentView.bounds.height)))
                scroll.reflectScrolledClipView(scroll.contentView)
                try capture(host, at: artifacts.appendingPathComponent(stem + "-bottom.png"))
            }
        }
        print("Onboarding light/dark capture matrix: \(artifacts.path)")
    }

    @Test func keyEntryIsSecureAndKeyboardSetupFailureKeepsThePlayerAndOffersRetry() async throws {
        _ = NSApplication.shared
        let environment = makePreviewEnvironment(.playing)
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
        _ = try AppearanceTestAccessibility.element("soloist.cancelSetup", in: content)
        #expect(environment.isShowingOnboarding)
        #expect(environment.playerMode == .expanded)
        #expect(environment.player?.state.currentTrack == originalTrack)
        #expect(!environment.soloist.hasUsablePlayback)
        content.layoutSubtreeIfNeeded()
        try capture(content, at: artifacts.appendingPathComponent("retry.png"))
        print("Soloist UI captures: \(artifacts.path)")
    }

    @Test func libraryRegistrationIsInlineAndValidatesBeforeConsent() async throws {
        _ = NSApplication.shared
        let environment = makePreviewEnvironment(.playing, libraryClientID: nil)
        let track = environment.player?.state.currentTrack
        environment.showOnboarding(section: .library)
        let window = NSWindow(contentRect: CGRect(x: 300, y: 300, width: 410, height: 480),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); environment.player?.stop() }
        let host = NSHostingView(rootView: PlayerRootView(environment: environment)
            .frame(width: 410, height: 480)
            .environment(\.accessibilityEnabled, true))
        host.sizingOptions = []
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        let content = try #require(window.contentView)
        try await Task.sleep(for: .milliseconds(180))
        let field = try #require(editableField(in: content))
        _ = try AppearanceTestAccessibility.element("onboarding.clientIDLabel", in: content)
        let save = try AppearanceTestAccessibility.element("onboarding.saveLibrary", in: content)
        #expect(save.object.isAccessibilityEnabled?() == false)
        field.selectText(nil)
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.insertText("invalid-client", replacementRange: editor.selectedRange())
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        try await Task.sleep(for: .milliseconds(80))
        let invalidSave = try AppearanceTestAccessibility.element("onboarding.saveLibrary", in: content)
        #expect(invalidSave.object.isAccessibilityEnabled?() == false)
        editor.selectAll(nil)
        editor.insertText(String(repeating: "a", count: 32), replacementRange: editor.selectedRange())
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        try await Task.sleep(for: .milliseconds(80))
        let validSave = try AppearanceTestAccessibility.element("onboarding.saveLibrary", in: content)
        #expect(validSave.object.isAccessibilityEnabled?() == true)
        #expect(window.firstResponder === editor)
        #expect(environment.libraryClientID == nil, "Typing alone must not replace or authorize a Spotify app")
        #expect(environment.player?.state.currentTrack == track)
        let artifacts = try captureDirectory()
        try capture(content, at: artifacts.appendingPathComponent("library-registration.png"))
        let scroll = try #require(scrollView(in: content))
        let document = try #require(scroll.documentView)
        #expect(document.frame.height > scroll.contentView.bounds.height)
        document.scroll(NSPoint(x: 0, y: document.frame.height - scroll.contentView.bounds.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(scroll.contentView.bounds.origin.y > 0)
        let playback = try AppearanceTestAccessibility.element("onboarding.playback", in: content)
        #expect(playback.press())
        #expect(environment.onboardingStep == .playback(.entry))
        environment.closeOnboarding()
        #expect(!environment.isShowingOnboarding)
        #expect(environment.player?.state.currentTrack == track)
        print("Library onboarding capture: \(artifacts.path)")
    }

    private func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
    }

    private func editableField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable, !(field is NSSecureTextField) { return field }
        return view.subviews.lazy.compactMap { editableField(in: $0) }.first
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
