import AppKit
import SwiftUI
import Testing
import BopifyPlayback

@MainActor @Suite("Library onboarding presentation", .serialized)
struct LibraryAuthorizationSetupViewTests {
    @Test func libraryConsentExplainsItsFourPermissionsBeforeConnecting() async throws {
        let environment = makePreviewEnvironment(.nothingPlaying, libraryClientID: nil)
        defer { environment.player?.stop() }
        let host = NSHostingView(rootView: LibraryAuthorizationSetupView(status: .idle, environment: environment)
            .frame(width: 340).environment(\.accessibilityEnabled, true))
        let window = window(for: host)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        for name in ["liked", "artists", "recent", "likes"] {
            _ = try AppearanceTestAccessibility.element("onboarding.permission.\(name)", in: host)
        }
        _ = try AppearanceTestAccessibility.element("onboarding.libraryClientID", in: host)
    }

    @Test func waitingForLibraryConsentHasNoCancelControl() async throws {
        let environment = makePreviewEnvironment(.nothingPlaying)
        defer { environment.player?.stop() }
        let host = NSHostingView(rootView: LibraryAuthorizationSetupView(status: .authorizing, environment: environment)
            .frame(width: 340).environment(\.accessibilityEnabled, true))
        let window = window(for: host)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        #expect(buttonCount(in: host) == 0)
    }

    @Test func editingLibraryRegistrationHasNoCancelControl() async throws {
        let environment = makePreviewEnvironment(.nothingPlaying)
        defer { environment.player?.stop() }
        let host = NSHostingView(rootView: LibraryAuthorizationSetupView(status: .idle, environment: environment)
            .frame(width: 340).environment(\.accessibilityEnabled, true))
        let window = window(for: host)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        let edit = try AppearanceTestAccessibility.element("onboarding.editLibrary", in: host)
        #expect(edit.press())
        try await Task.sleep(for: .milliseconds(100))
        _ = try AppearanceTestAccessibility.element("onboarding.libraryClientID", in: host)
        #expect(buttonCount(in: host) == 2, "Registration offers its guide and connect action")
    }

    private func window<Content: View>(for host: NSHostingView<Content>) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 120, y: 120, width: 360, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        host.sizingOptions = []
        window.contentView = host
        window.orderFront(nil)
        return window
    }

    private func buttonCount(in root: Any) -> Int {
        var visited = Set<ObjectIdentifier>()
        func count(_ object: Any) -> Int {
            let node = object as AnyObject
            guard visited.insert(ObjectIdentifier(node)).inserted else { return 0 }
            let own = node.accessibilityRole?() == .button ? 1 : 0
            let children = (node.accessibilityChildren?() ?? []) + (node.accessibilityContents?() ?? [])
            let subviews = (object as? NSView)?.subviews ?? []
            return own + children.reduce(0) { $0 + count($1) } + subviews.reduce(0) { $0 + count($1) }
        }
        return count(root)
    }
}
