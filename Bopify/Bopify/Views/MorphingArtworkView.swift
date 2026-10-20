import SwiftUI

struct MorphingArtworkView: View {
    let image: Image?
    let diameter: CGFloat
    let occurrenceID: String
    var isVisible = true
    var reduceMotionOverride = false
    @State private var morph: ArtworkMorphState
    @State private var isAnimating = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || reduceMotionOverride }

    init(image: Image?, diameter: CGFloat, occurrenceID: String = "", isVisible: Bool = true, reduceMotionOverride: Bool = false) {
        self.image = image
        self.diameter = diameter
        self.occurrenceID = occurrenceID
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
        morph.transition(to: image, occurrenceID: occurrenceID, at: .now, diameter: diameter)
        isAnimating = isVisible
        if !isVisible { morph.finish() }
    }
}
