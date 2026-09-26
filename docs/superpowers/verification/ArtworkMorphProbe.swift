import SwiftUI

// Compile alongside ArtworkMorphState.swift and ArtworkView.swift; this exercises the state used by the visible overlay.
@main struct ArtworkMorphProbe {
    @MainActor static func pixel(_ frames: [ArtworkMorphFrame]) -> NSColor {
        let renderer = ImageRenderer(content: ZStack {
            ForEach(frames) { frame in
                ArtworkView(image: frame.image, diameter: 204).opacity(frame.opacity)
            }
        })
        let bitmap = NSBitmapImageRep(data: renderer.nsImage!.tiffRepresentation!)!
        return bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)!.usingColorSpace(.sRGB)!
    }

    @MainActor static func main() {
        if CommandLine.arguments.contains("--stress") {
            var stress = ArtworkMorphState(image: Image(systemName: "a.circle"))
            for n in 0..<100 {
                stress.transition(to: Image(systemName: n.isMultiple(of: 2) ? "b.circle" : "c.circle"), at: Date(timeIntervalSinceReferenceDate: Double(n) * 0.1))
            }
            precondition(stress.frames(at: Date(timeIntervalSinceReferenceDate: 9.91)).count <= 2, "interrupted covers must stay bounded")
            print("PASS: 100 interruptions retain at most two artwork layers")
            return
        }
        let a = Image(nsImage: ImageRenderer(content: Color.red.frame(width: 204, height: 204)).nsImage!)
        let b = Image(nsImage: ImageRenderer(content: Color.green.frame(width: 204, height: 204)).nsImage!)
        let c = Image(nsImage: ImageRenderer(content: Color.blue.frame(width: 204, height: 204)).nsImage!)
        let start = Date(timeIntervalSinceReferenceDate: 0)
        var morph = ArtworkMorphState(image: a)
        morph.transition(to: b, at: start)
        let first = morph.frames(at: start)
        precondition(first.count == 2 && first[0].opacity == 1 && first[1].opacity == 0)
        let middle = morph.frames(at: start.addingTimeInterval(0.21))
        precondition(middle[0].image == a && middle[0].opacity == 1)
        precondition(abs(middle[1].opacity - 0.5) < 0.001)
        let phaseBefore = sin(morph.phase(at: start.addingTimeInterval(0.21)) * .pi)
        morph.transition(to: c, at: start.addingTimeInterval(0.21))
        let interrupted = morph.frames(at: start.addingTimeInterval(0.21))
        let phaseAfter = sin(morph.phase(at: start.addingTimeInterval(0.21)) * .pi)
        precondition(abs(phaseBefore - phaseAfter) < 0.001, "interrupted deformation must not snap")
        precondition(interrupted.count == 2 && interrupted[0].opacity == 1 && interrupted[1].opacity == 0)
        let before = pixel(middle)
        let after = pixel(interrupted)
        precondition(abs(before.redComponent - after.redComponent) < 0.01)
        precondition(abs(before.greenComponent - after.greenComponent) < 0.01)
        precondition(abs(before.blueComponent - after.blueComponent) < 0.01)
        precondition(morph.frames(at: start.addingTimeInterval(0.63)).last!.opacity == 1)
        morph.finish()
        precondition(morph.frames(at: start.addingTimeInterval(1)).count == 1)
        precondition(morph.frames(at: start.addingTimeInterval(1)).first!.image == c)
        morph.transition(to: nil, at: start.addingTimeInterval(1))
        precondition(morph.frames(at: start.addingTimeInterval(1.42)).last!.image == nil)
        morph.transition(to: a, at: start.addingTimeInterval(1.5))
        morph.finish()
        precondition(morph.frames(at: start.addingTimeInterval(2)).first!.image == a)
        morph.transition(to: a, at: start.addingTimeInterval(3))
        precondition(morph.frames(at: start.addingTimeInterval(3)).count == 1)
        print("PASS: opaque base, midpoint blend, interruption continuity, completion, missing/late art, unchanged image")
    }
}
