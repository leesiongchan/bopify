import SwiftUI

/// Both rectangles are captured in the temporary native window's coordinate space.
struct OnboardingHandoffGeometry: Equatable {
    let id: UUID
    let source: CGRect
    let destination: CGRect

    func recordFrame(at progress: CGFloat) -> CGRect {
        let fraction = OnboardingHandoffVisuals.ramp(progress, from: 0.18, to: 0.84)
        return CGRect(x: source.minX + (destination.minX - source.minX) * fraction,
                      y: source.minY + (destination.minY - source.minY) * fraction,
                      width: source.width + (destination.width - source.width) * fraction,
                      height: source.height + (destination.height - source.height) * fraction)
    }
}

struct OnboardingHandoffVisuals {
    let progress: CGFloat

    var setupOpacity: Double { 1 }
    var backgroundOpacity: Double { Double(1 - Self.ramp(progress, from: 0, to: 0.30)) }
    var pocketOpacity: Double { Double(1 - Self.ramp(progress, from: 0, to: 0.16)) }
    var sourceRecordOpacity: Double { progress < 0.18 ? 1 : 0 }
    var transferOpacity: Double { progress < 0.18 ? 0 : 1 - playerRecordOpacity }
    var playerOpacity: Double { Double(Self.ramp(progress, from: 0.15, to: 0.72)) }
    var playerRecordOpacity: Double { Double(Self.ramp(progress, from: 0.86, to: 1)) }

    static func ramp(_ progress: CGFloat, from start: CGFloat, to end: CGFloat) -> CGFloat {
        let value = min(1, max(0, (progress - start) / (end - start)))
        return value * value * (3 - 2 * value)
    }
}

/// Re-evaluate the coordinated layers at the interpolated progress, not just its model endpoint.
struct OnboardingHandoffScene<Content: View>: View, Animatable {
    var progress: CGFloat
    @ViewBuilder var content: (OnboardingHandoffVisuals) -> Content

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        content(OnboardingHandoffVisuals(progress: min(1, max(0, progress))))
    }
}

struct OnboardingTransferRecord: View {
    let geometry: OnboardingHandoffGeometry
    let progress: CGFloat
    let side: RecordSide
    var onRecordFrameChanged: ((CGRect) -> Void)?

    var body: some View {
        let frame = geometry.recordFrame(at: progress)
        RecordDisc(angle: .zero, side: side, isSad: false, reflection: nil)
            .scaleEffect(x: frame.width / 200, y: frame.height / 200)
            .frame(width: frame.width, height: frame.height)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onRecordFrameChanged?($0) }
            .position(x: frame.midX, y: frame.midY)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
