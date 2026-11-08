import SwiftUI

struct MorphingArtworkView: View {
    let image: Image?
    let diameter: CGFloat
    let occurrenceID: String
    var isVisible = true
    var transitionDuration: TimeInterval = 0.65
    @State private var morph: ArtworkMorphState
    @State private var isAnimating = false

    init(image: Image?, diameter: CGFloat, occurrenceID: String = "", isVisible: Bool = true, transitionDuration: TimeInterval = 0.65) {
        self.image = image
        self.diameter = diameter
        self.occurrenceID = occurrenceID
        self.isVisible = isVisible
        self.transitionDuration = transitionDuration
        _morph = State(initialValue: ArtworkMorphState(image: image, occurrenceID: occurrenceID))
    }

    var body: some View {
        TimelineView(.animation(paused: !isAnimating || !isVisible)) { _ in
            ZStack {
                ForEach(morph.frames(at: SuspendingClock.now)) { frame in
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
            do { try await Task.sleep(for: .seconds(morph.duration), clock: .suspending) } catch { return }
            morph.finish()
            isAnimating = false
        }
        .accessibilityHidden(true)
    }

    private func retarget() {
        morph.duration = transitionDuration
        morph.transition(to: image, occurrenceID: occurrenceID, at: SuspendingClock.now, diameter: diameter)
        isAnimating = isVisible
        if !isVisible { morph.finish() }
    }
}
