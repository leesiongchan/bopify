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
        environment.soloistSetupWindow.show(environment: environment)
        defer { environment.soloistSetupWindow.close(); environment.player?.stop() }
        let window = try #require(NSApp.windows.first { $0.title == SoloistResources.string("soloist.title") && $0.isVisible })
        window.contentView = NSHostingView(rootView: SoloistSetupView(environment: environment).environment(\.accessibilityEnabled, true))
        let content = try #require(window.contentView)
        try await Task.sleep(for: .milliseconds(150))
        let field = try #require(secureField(in: content))
        let cell = try #require(field.cell as? NSSecureTextFieldCell)
        #expect(cell.echosBullets)
        #expect(cell.accessibilitySubrole() == .secureTextField)
        #expect(cell.accessibilityPlaceholderValue() == SoloistResources.string("soloist.key"))
        #expect(field.isEditable)
        let enable = try AppearanceTestAccessibility.element("soloist.enable", in: content)
        #expect(enable.object.accessibilityRole?() == .button)
        _ = try AppearanceTestAccessibility.element("soloist.useLibrespot", in: content)
        let artifacts = try captureDirectory()
        try capture(content, at: artifacts.appendingPathComponent("initial.png"))
        field.selectText(nil)
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.insertText("fixture-key", replacementRange: editor.selectedRange())
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        try await Task.sleep(for: .milliseconds(80))
        #expect(field.stringValue == "fixture-key")
        #expect(window.firstResponder === editor)
        let updatedEnable = try AppearanceTestAccessibility.element("soloist.enable", in: content)
        #expect(updatedEnable.press())
        try await liveLyricEventually {
            if case .failed = environment.soloist.phase { return true }; return false
        }
        #expect(environment.player?.state.currentTrack == originalTrack)
        #expect(environment.player?.state.phase == .playing)
        content.layoutSubtreeIfNeeded()
        try capture(content, at: artifacts.appendingPathComponent("retry.png"))
        print("Soloist UI captures: \(artifacts.path)")
    }

    private func secureField(in view: NSView) -> NSSecureTextField? {
        if let field = view as? NSSecureTextField { return field }
        return view.subviews.lazy.compactMap { secureField(in: $0) }.first
    }

    private func captureDirectory() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let destination = root.appendingPathComponent("build/test-artifacts/soloist-setup/\(UUID().uuidString)")
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
