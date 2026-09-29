import SwiftUI
import os
import BopifyDomain
import BopifyPlayback

struct MorphingArtworkView: View {
    let image: Image?
    let diameter: CGFloat
    let occurrenceID: String
    let direction: CarouselDirection
    var isVisible = true
    var reduceMotionOverride = false
    @State private var morph: ArtworkMorphState
    @State private var isAnimating = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || reduceMotionOverride }

    init(image: Image?, diameter: CGFloat, occurrenceID: String = "", direction: CarouselDirection = .fade, isVisible: Bool = true, reduceMotionOverride: Bool = false) {
        self.image = image
        self.diameter = diameter
        self.occurrenceID = occurrenceID
        self.direction = direction
        self.isVisible = isVisible
        self.reduceMotionOverride = reduceMotionOverride
        _morph = State(initialValue: ArtworkMorphState(image: image, occurrenceID: occurrenceID))
    }

    var body: some View {
        TimelineView(.animation(paused: !isAnimating || !isVisible)) { context in
            ZStack {
                ForEach(morph.frames(at: context.date)) { frame in
                    ArtworkView(image: frame.image, diameter: diameter).opacity(frame.opacity)
                }
            }
            .clipShape(Circle())
        }
        .frame(width: diameter, height: diameter)
        .onChange(of: image) { _, _ in retarget() }
        .onChange(of: occurrenceID) { _, _ in retarget() }
        .onChange(of: isVisible) { _, visible in
            if !visible { morph.finish(); isAnimating = false }
        }
        .task(id: morph.generation) {
            guard isAnimating else { return }
            do { try await Task.sleep(for: .seconds(morph.duration)) } catch { return }
            morph.finish()
            isAnimating = false
        }
        .accessibilityHidden(true)
    }

    private func retarget() {
        morph.duration = reduceMotion ? 0.16 : 0.65
        morph.transition(to: image, occurrenceID: occurrenceID, direction: direction, at: .now, diameter: diameter)
        isAnimating = isVisible
        if !isVisible { morph.finish() }
        BopifyLog.playback.debug("artwork blend retargeted")
    }
}
