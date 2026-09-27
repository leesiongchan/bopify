#if DEBUG
import SwiftUI
import Observation
import BopifyDomain
import BopifyPlayback

// Original vector samples for native previews; never used for missing live artwork.
func previewArtworkURL(_ index: Int) -> URL { URL(string: "https://preview.invalid/sample/\(index)")! }

func previewArtworkStore() -> ArtworkStore {
    var images: [URL: NSImage] = [:]
    for index in 0..<3 {
        let colors: [Color] = switch index {
        case 0: [.cyan, .teal, .black]
        case 1: [.indigo, .pink, .orange]
        default: [Color(red: 0.9, green: 0.79, blue: 0.65), .orange, .brown]
        }
        let renderer = ImageRenderer(content: ZStack {
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            if index == 2 {
                ForEach(0..<8) { petal in
                    Ellipse().fill(.pink.opacity(0.7)).frame(width: 72, height: 130)
                        .offset(y: -35).rotationEffect(.degrees(Double(petal) * 45))
                }
                Circle().fill(.yellow.opacity(0.9)).frame(width: 45, height: 45)
            } else {
                ForEach(0..<5) { line in
                    Ellipse().stroke(.white.opacity(0.45), lineWidth: 2)
                        .frame(width: 90 + CGFloat(line) * 26, height: 220)
                        .rotationEffect(.degrees(index == 0 ? 35 : -35))
                }
            }
        }.frame(width: 240, height: 240).clipped())
        if let image = renderer.nsImage { images[previewArtworkURL(index)] = image }
    }
    return ArtworkStore(previewImages: images)
}
@MainActor @Observable final class MonolithRecordFixture {
    let store = previewArtworkStore()
    var index = 1
    var occurrenceID = "first"
    var direction: CarouselDirection = .next
    var playing = true
    var visible = true
    var missing = false
    var reducedMotion = false
    var diameter: CGFloat = 182
    var image: Image? {
        missing ? nil : store.images[previewArtworkURL(index)].map { Image(nsImage: $0) }
    }
}

struct MonolithRecordScene: View {
    let fixture: MonolithRecordFixture
    var body: some View {
        VinylRecordView(image: fixture.image, occurrenceID: fixture.occurrenceID, direction: fixture.direction,
                        diameter: fixture.diameter, isPlaying: fixture.playing, isVisible: fixture.visible,
                        reduceMotionOverride: fixture.reducedMotion)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview("Monolith vinyl") { MonolithRecordScene(fixture: MonolithRecordFixture()).frame(width: 264, height: 264) }
#endif
