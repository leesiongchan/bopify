import SwiftUI
import os
import BopifyDomain

struct MorphingArtworkView: View {
    let image: Image?
    let diameter: CGFloat
    @State private var morph: ArtworkMorphState
    @State private var animating = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(image: Image?, diameter: CGFloat) {
        self.image = image
        self.diameter = diameter
        _morph = State(initialValue: ArtworkMorphState(image: image))
    }

    var body: some View {
        TimelineView(.animation(paused: !animating)) { context in
            let progress = morph.phase(at: context.date)
            let strength = reduceMotion ? 0 : sin(progress * .pi)
            ZStack {
                ForEach(morph.frames(at: context.date)) { frame in
                    ArtworkView(image: frame.image, diameter: diameter)
                        .opacity(frame.opacity)
                }
            }
            .drawingGroup()
            .distortionEffect(ShaderLibrary.artworkLens(.float(diameter), .float(strength), .float(progress)),
                              maxSampleOffset: CGSize(width: diameter * 0.12, height: diameter * 0.12),
                              isEnabled: !reduceMotion && animating)
            .overlay {
                LinearGradient(colors: [.clear, .white.opacity(0.28), .clear],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .offset(x: diameter * (progress - 0.5))
                    .opacity(reduceTransparency ? 0 : strength)
            }
            .clipShape(Circle())
            .scaleEffect(x: 1 - 0.06 * strength, y: 1 - 0.025 * strength)
        }
        .frame(width: diameter, height: diameter)
        .onChange(of: image) { _, next in
            morph.duration = reduceMotion ? 0.16 : 0.42
            morph.transition(to: next, at: .now, diameter: diameter)
            animating = true
            BopifyLog.playback.debug("artwork morph retargeted")
        }
        .task(id: morph.generation) {
            guard animating else { return }
            try? await Task.sleep(for: .seconds(morph.duration))
            guard !Task.isCancelled else { return }
            morph.finish()
            animating = false
        }
        .accessibilityHidden(true)
    }
}
