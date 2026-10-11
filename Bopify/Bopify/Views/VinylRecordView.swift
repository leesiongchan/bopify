import SwiftUI
import BopifyPlayback

struct VinylRecordView: View {
    let image: Image?
    let occurrenceID: String
    let direction: CarouselDirection
    let diameter: CGFloat
    let isMoving: Bool
    let isVisible: Bool
    let rotation: RecordRotation
    var rotationOverride: Double? = nil
    var isScrubbing = false
    var isEngaged = false
    var reduceMotionOverride = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var tilt = 0.0
    @State private var depth = 1.0
    @State private var kick = 0.0
    private var reduceMotion: Bool { systemReduceMotion || reduceMotionOverride }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isMoving || !isVisible || reduceMotion || isScrubbing)) { _ in
            ZStack {
                ZStack {
                    Circle().fill(Color(red: 0.035, green: 0.055, blue: 0.05))
                    ForEach(0..<18) { groove in
                        Circle().stroke(.white.opacity(groove.isMultiple(of: 3) ? 0.065 : 0.025), lineWidth: 0.6)
                            .padding(5 + CGFloat(groove) * diameter * 0.012)
                    }
                    MorphingArtworkView(image: image, diameter: diameter * 0.43,
                                        occurrenceID: occurrenceID, direction: direction, isVisible: isVisible, reduceMotionOverride: reduceMotion)
                        .overlay(Circle().stroke(.black.opacity(0.4), lineWidth: 1))
                }
                .rotationEffect(.radians(rotationOverride ?? rotation.angle(at: ProcessInfo.processInfo.systemUptime)))
                // A separate layer so the animated kick never fights the clock-driven spin or scrubbing.
                .rotationEffect(.degrees(kick))
                Circle().fill(AngularGradient(stops: [
                    .init(color: .black.opacity(0.3), location: 0),
                    .init(color: .white.opacity(0.16), location: 0.16),
                    .init(color: .black.opacity(0.35), location: 0.30),
                    .init(color: .white.opacity(0.12), location: 0.62),
                    .init(color: .black.opacity(0.3), location: 1)
                ], center: .center, startAngle: .degrees(15), endAngle: .degrees(375)))
                    .padding(3)
                Circle().fill(.black.opacity(0.7)).frame(width: 3, height: 3)
                Circle().strokeBorder(.white.opacity(contrast == .increased ? 0.75 : 0.3), lineWidth: 0.75)
            }
        }
        .frame(width: diameter, height: diameter)
        .scaleEffect(depth)
        .rotation3DEffect(.degrees(tilt), axis: (x: 0.3, y: 1, z: 0), perspective: 0.3)
        .shadow(color: .black.opacity(0.28), radius: 9, x: 0, y: 6)
        .onChange(of: occurrenceID) { _, _ in
            guard !reduceMotion, isVisible, direction != .fade else { return }
            withAnimation(.spring(duration: 0.25, bounce: 0)) {
                tilt = direction == .next ? -12 : 12
                depth = 0.94
            }
        }
        .task(id: occurrenceID) {
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            withAnimation(.spring(duration: reduceMotion ? 0.16 : 0.50, bounce: 0.08)) {
                tilt = 0
                depth = 1
            }
        }
        .onChange(of: isEngaged) { _, engaged in
            // Only forward: a record doesn't unwind when the sleeve closes.
            guard engaged, isVisible, !reduceMotion else { return }
            withAnimation(.easeOut(duration: 0.9)) { kick += 220 }
        }
        .onChange(of: isVisible) { _, visible in if !visible { tilt = 0; depth = 1 } }
        .onChange(of: reduceMotion) { _, reduced in if reduced { tilt = 0; depth = 1 } }
        .accessibilityHidden(true)
    }
}
