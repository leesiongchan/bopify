import AppKit
import SwiftUI
import Testing

@MainActor @Suite("Onboarding motion rendering", .serialized)
struct OnboardingMotionRenderingTests {
    @Test func handoffRendersIntermediateFramesBeforeItsCompletionCallback() async throws {
        _ = NSApplication.shared
        let probe = HandoffRenderingProbe()
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 300, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: HandoffRenderingProbeView(probe: probe))
        window.orderFrontRegardless()
        defer { window.close() }
        try await liveLyricEventually { probe.widths.contains { $0 <= 21 } }
        probe.showingPlayer = true
        await Task.yield()
        withAnimation(.linear(duration: 0.65), completionCriteria: .removed) {
            probe.progress = 1
        } completion: {
            probe.completed = true
        }
        try await Task.sleep(for: .milliseconds(180))
        #expect(probe.widths.contains { $0 > 25 && $0 < 195 },
                "A scheduled animation must render intermediate values, not just signal a delayed completion")
        try await liveLyricEventually { probe.completed }
        #expect(probe.widths.contains { $0 >= 199 })
    }
}

@MainActor @Observable
private final class HandoffRenderingProbe {
    var progress: CGFloat = 0
    var showingPlayer = false
    var completed = false
    @ObservationIgnored var widths: [CGFloat] = []
}

private struct HandoffRenderingProbeView: View {
    let probe: HandoffRenderingProbe

    var body: some View {
        OnboardingHandoffScene(progress: probe.progress) { visual in
            Color.green.frame(width: 20 + 180 * visual.progress, height: 30)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { probe.widths.append($0) }
        }
        .animation(probe.showingPlayer ? nil : .easeInOut(duration: 0.5), value: probe.showingPlayer)
    }
}
