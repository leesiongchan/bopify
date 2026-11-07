import AppKit
import SwiftUI
import Testing
import BopifyDomain
import BopifyPlayback

@MainActor @Suite("Soloist native presentation", .serialized)
struct SoloistSetupRenderingTests {
    @Test func keyEntryIsSecureAndKeyboardSetupFailurePreservesTheExistingPlayer() async throws {
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
        #expect(cell.accessibilityPlaceholderValue() == SoloistResources.string("soloist.key"))
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
        _ = try AppearanceTestAccessibility.element("soloist.useLibrespot", in: content)
        #expect(environment.isShowingOnboarding)
        #expect(environment.playerMode == .expanded)
        #expect(environment.player?.state.currentTrack == originalTrack)
        #expect(environment.player?.state.phase == .playing)
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
