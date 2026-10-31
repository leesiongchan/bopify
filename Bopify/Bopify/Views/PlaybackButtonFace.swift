import SwiftUI

struct PlaybackButtonFace: View {
    let isPlaying: Bool
    let previousPlaying: Bool
    let progress: Double
    var reduceMotion = false

    var body: some View {
        let p = reduceMotion ? 1 : min(1, max(0, progress))
        let outgoing = min(1, p / 0.5)
        let incoming = min(1, max(0, (p - 0.35) / 0.65))
        let depth = sin(p * .pi)
        ZStack {
            Circle().fill(.primary.opacity(0.1 + depth * 0.12))
            glyph(previousPlaying)
                .rotation3DEffect(.degrees(-90 * outgoing), axis: (x: 1, y: 0, z: 0), perspective: 0.4)
                .opacity(1 - outgoing)
            glyph(isPlaying)
                .rotation3DEffect(.degrees(90 * (1 - incoming)), axis: (x: 1, y: 0, z: 0), perspective: 0.4)
                .opacity(incoming)
            Circle().strokeBorder(LinearGradient(colors: [
                .white.opacity(0.1 + depth * 0.4), .black.opacity(depth * 0.3), .white.opacity(0.08)
            ], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
        }
        .frame(width: 48, height: 48)
        .scaleEffect(1 - depth * 0.035)
        .shadow(color: .black.opacity(depth * 0.25), radius: 3, y: depth * 2)
    }

    private func glyph(_ playing: Bool) -> some View {
        Image(systemName: playing ? "pause.fill" : "play.fill")
            .font(.system(size: 23, weight: .semibold))
            .offset(x: playing ? 0 : 2)
    }
}
