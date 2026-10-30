import SwiftUI

/// Mint, orange and teal light drifting behind the startup content, in the logo's palette.
struct AuroraBackground: View {
    var isAnimating = true
    var isDimmed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private struct Blob {
        let color: Color
        /// Size and origin as fractions of the field; drift is a fraction of the blob's own size.
        let size: CGSize
        let origin: CGPoint
        let drift: CGSize
        let scale: CGFloat
        let period: Double
    }

    private static let blobs = [
        Blob(color: Color(red: 0.65, green: 0.85, blue: 0.74), size: CGSize(width: 0.6, height: 0.5),
             origin: CGPoint(x: 0.1, y: 0.15), drift: CGSize(width: 0.25, height: 0.2), scale: 1.15, period: 11),
        Blob(color: Color(red: 1, green: 0.48, blue: 0.1), size: CGSize(width: 0.5, height: 0.45),
             origin: CGPoint(x: 0.45, y: 0.4), drift: CGSize(width: -0.3, height: -0.15), scale: 0.9, period: 13),
        Blob(color: Color(red: 0.11, green: 0.36, blue: 0.32), size: CGSize(width: 0.7, height: 0.5),
             origin: CGPoint(x: 0.2, y: 0.6), drift: CGSize(width: 0.1, height: -0.25), scale: 1.2, period: 9),
    ]

    var body: some View {
        // Solid surfaces stay solid: the aurora would undercut the contrast those settings ask for.
        if !reduceTransparency && contrast != .increased {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isAnimating || reduceMotion)) { context in
                let time = context.date.timeIntervalSinceReferenceDate
                GeometryReader { geometry in
                    // The field overhangs the surface so the blur never reveals an edge.
                    let field = CGSize(width: geometry.size.width * 1.6, height: geometry.size.height * 1.6)
                    ZStack(alignment: .topLeading) {
                        ForEach(Self.blobs.indices, id: \.self) { index in
                            blob(Self.blobs[index], in: field, progress: reduceMotion ? 0 : (1 - cos(.pi * time / Self.blobs[index].period)) / 2)
                        }
                    }
                    .frame(width: field.width, height: field.height, alignment: .topLeading)
                    .compositingGroup()
                    .blur(radius: 50)
                    .offset(x: -geometry.size.width * 0.3, y: -geometry.size.height * 0.3)
                }
            }
            .saturation(isDimmed ? 0.3 : 1)
            .opacity(isDimmed ? 0.45 : 0.85)
            .animation(.easeInOut(duration: reduceMotion ? 0.16 : 0.8), value: isDimmed)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func blob(_ blob: Blob, in field: CGSize, progress: Double) -> some View {
        let size = CGSize(width: field.width * blob.size.width, height: field.height * blob.size.height)
        return Ellipse().fill(blob.color)
            .frame(width: size.width, height: size.height)
            .scaleEffect(1 + (blob.scale - 1) * progress)
            .offset(x: field.width * blob.origin.x + size.width * blob.drift.width * progress,
                    y: field.height * blob.origin.y + size.height * blob.drift.height * progress)
            .blendMode(.screen)
    }
}
