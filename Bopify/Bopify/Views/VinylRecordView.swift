import SwiftUI
import BopifyPlayback

struct VinylRecordView: View, Animatable {
    let image: Image?
    let occurrenceID: String
    let direction: CarouselDirection
    var diameter: CGFloat
    let isMoving: Bool
    let isVisible: Bool
    let rotation: RecordRotation
    var pressingSeed: Float = 0
    var palette: ArtworkPalette = .neutral
    var design: VinylDesign = .original
    var artworkRotationOffset = 0.0
    var rotationOverride: Double? = nil
    var isScrubbing = false
    var reduceMotionOverride = false
    var loadProgress = 1.0
    var labelRatio: CGFloat = 0.43
    var isIncomingDuringLoad = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var tilt = 0.0
    @State private var depth = 1.0
    private var reduceMotion: Bool { systemReduceMotion || reduceMotionOverride }
    var animatableData: CGFloat {
        get { diameter }
        set { diameter = newValue }
    }
    private var labelSize: CGFloat { min(diameter - 8, diameter * labelRatio) }
    private var revealedDiameter: CGFloat {
        isIncomingDuringLoad ? labelSize + (diameter - labelSize) * RecordLoadStage(progress: loadProgress).expansion : diameter
    }
    private var revealMask: some View {
        Circle().frame(width: revealedDiameter, height: revealedDiameter)
            .blur(radius: isIncomingDuringLoad ? sin(.pi * RecordLoadStage(progress: loadProgress).expansion) * 1.5 : 0)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isMoving || !isVisible || reduceMotion || isScrubbing)) { _ in
            ZStack {
                Circle().fill(Color(white: 0.016))
                    .offset(y: diameter * 0.0125)
                    .mask(revealMask)
                ZStack {
                    VinylPressingView(seed: pressingSeed, palette: palette, design: design, diameter: diameter)
                        .id(PressingAppearance(seed: pressingSeed, palette: palette, design: design))
                        .transition(.opacity)
                        .animation(isVisible && !isIncomingDuringLoad ? .easeInOut(duration: reduceMotion ? 0.16 : 0.65) : nil,
                                   value: PressingAppearance(seed: pressingSeed, palette: palette, design: design))
                        .mask(revealMask)
                    RecordDust().mask(revealMask)
                    MorphingArtworkView(image: image, diameter: labelSize,
                                        occurrenceID: occurrenceID, isVisible: isVisible,
                                        reduceMotionOverride: reduceMotion || loadProgress < 1)
                        .overlay(Circle().stroke(.black.opacity(0.4), lineWidth: 1))
                        .rotationEffect(.radians(artworkRotationOffset))
                }
                .rotationEffect(.radians(rotationOverride ?? rotation.angle(at: ProcessInfo.processInfo.systemUptime)))
                Circle().fill(.black.opacity(0.7)).frame(width: 3, height: 3)
                Circle().strokeBorder(.white.opacity(contrast == .increased ? 0.75 : 0.3), lineWidth: 0.75)
                    .frame(width: revealedDiameter, height: revealedDiameter)
            }
        }
        .frame(width: diameter, height: diameter)
        .opacity(isIncomingDuringLoad ? RecordLoadStage(progress: loadProgress).incomingOpacity : 1)
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
        .onChange(of: isVisible) { _, visible in if !visible { tilt = 0; depth = 1 } }
        .onChange(of: reduceMotion) { _, reduced in if reduced { tilt = 0; depth = 1 } }
        .accessibilityHidden(true)
    }
}
