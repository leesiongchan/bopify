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
                Circle().fill(Color(white: 0.016))
                    .offset(y: diameter * 0.0125)
                VinylPressingView(diameter: diameter)
                ZStack {
                    RecordDust()
                    MorphingArtworkView(image: image, diameter: diameter * 0.43,
                                        occurrenceID: occurrenceID, isVisible: isVisible, reduceMotionOverride: reduceMotion)
                        .overlay(Circle().stroke(.black.opacity(0.4), lineWidth: 1))
                }
                .rotationEffect(.radians(rotationOverride ?? rotation.angle(at: ProcessInfo.processInfo.systemUptime)))
                // A separate layer so the animated kick never fights the clock-driven spin or scrubbing.
                .rotationEffect(.degrees(kick))
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
