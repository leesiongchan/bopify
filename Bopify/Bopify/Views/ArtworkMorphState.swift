import SwiftUI
import BopifyPlayback

struct ArtworkMorphFrame: Identifiable {
    let id: UUID
    let image: Image?
    var opacity: Double
}

@MainActor struct ArtworkMorphState {
    private var retained: [ArtworkMorphFrame]
    private var started: Date?
    private var phaseStart = 0.0
    var duration = 0.42
    private(set) var generation = 0
    private(set) var occurrenceID: String
    private(set) var navigationDirection: CarouselDirection = .fade

    init(image: Image?, occurrenceID: String = "") {
        self.occurrenceID = occurrenceID
        retained = [ArtworkMorphFrame(id: UUID(), image: image, opacity: 1)]
    }

    func progress(at date: Date) -> Double {
        guard let started else { return 1 }
        return min(1, max(0, date.timeIntervalSince(started) / duration))
    }

    func frames(at date: Date) -> [ArtworkMorphFrame] {
        var result = retained
        let t = progress(at: date)
        let blend = t * t * (3 - 2 * t)
        result[result.count - 1].opacity += (1 - result[result.count - 1].opacity) * blend
        return result
    }

    func phase(at date: Date) -> Double {
        phaseStart + (1 - phaseStart) * progress(at: date)
    }

    mutating func transition(to image: Image?, occurrenceID: String = "", direction: CarouselDirection = .fade,
                             at date: Date, diameter: CGFloat = 204) {
        guard retained.last?.image != image || self.occurrenceID != occurrenceID else { return }
        navigationDirection = self.occurrenceID == occurrenceID ? .fade : direction
        self.occurrenceID = occurrenceID
        let nextPhase = progress(at: date) < 1 ? phase(at: date) : 0
        // Flatten only interrupted blends, preserving their visible colors with at most two live layers.
        retained = frames(at: date)
        if retained.last?.opacity == 1 { retained = [retained.last!] }
        if retained.count > 1 {
            let renderer = ImageRenderer(content: ZStack {
                ForEach(retained) { frame in
                    ArtworkView(image: frame.image, diameter: max(204, diameter)).opacity(frame.opacity)
                }
            })
            renderer.scale = 2
            let snapshot = renderer.nsImage.map { Image(nsImage: $0) } ?? retained.last!.image
            retained = [ArtworkMorphFrame(id: UUID(), image: snapshot, opacity: 1)]
        }
        retained.append(ArtworkMorphFrame(id: UUID(), image: image, opacity: 0))
        phaseStart = nextPhase
        started = date
        generation += 1
    }

    mutating func finish() {
        retained = [ArtworkMorphFrame(id: retained.last!.id, image: retained.last!.image, opacity: 1)]
        started = nil
        phaseStart = 0
    }
}
