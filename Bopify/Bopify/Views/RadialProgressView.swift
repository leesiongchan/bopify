import SwiftUI
import BopifyPlayback

struct RadialProgressView: View {
    let positionMs: Int64
    let durationMs: Int64
    let canSeek: Bool
    let seek: (Int64) -> Void
    @State private var scrub: RadialScrub?
    @State private var rejectedGesture = false
    @GestureState private var gestureActive = false

    private var progress: Double {
        scrub?.progress ?? (durationMs > 0 ? min(1, max(0, Double(positionMs) / Double(durationMs))) : 0)
    }
    private var displayedPosition: Int64 { seekPosition(progress: progress, durationMs: durationMs) ?? 0 }

    var body: some View {
        GeometryReader { geometry in
            let radius = geometry.size.width / 2
            let angle = progress * .pi * 2 - .pi / 2
            ZStack {
                Circle().trim(from: 0, to: progress)
                    .stroke(.white.opacity(0.46), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if durationMs > 0 {
                    Circle().fill(Color(red: 0.79, green: 0.9, blue: 1))
                        .frame(width: 8, height: 8)
                        .shadow(color: .cyan.opacity(0.55), radius: 5)
                        .position(x: radius + cos(angle) * radius, y: radius + sin(angle) * radius)
                }
            }
            .contentShape(RingHitShape(), eoFill: true)
            .gesture(DragGesture(minimumDistance: 0)
                .updating($gestureActive) { _, state, _ in state = true }
                .onChanged { value in
                    guard canSeek, durationMs > 0, !rejectedGesture else { return }
                    let x = value.location.x - radius, y = value.location.y - radius
                    guard let fraction = radialProgress(x: x, y: y) else { return }
                    if scrub == nil {
                        guard abs(hypot(x, y) - radius) <= 18 else { rejectedGesture = true; return }
                        scrub = RadialScrub(start: fraction)
                    } else { scrub?.update(fraction) }
                }
                .onEnded { _ in
                    if canSeek, let scrub, let target = seekPosition(progress: scrub.progress, durationMs: durationMs) { seek(target) }
                    scrub = nil
                    rejectedGesture = false
                })
            .overlay(alignment: .bottom) {
                HStack {
                    Text(playbackTime(displayedPosition))
                    Spacer()
                    Text("−" + playbackTime(max(0, durationMs - displayedPosition)))
                }
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
                .padding(.horizontal, 20)
                .offset(y: 18)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("player.progress"))
        .accessibilityValue(Text("\(playbackTime(displayedPosition)) of \(playbackTime(durationMs))"))
        .accessibilityAdjustableAction { direction in
            guard canSeek else { return }
            let delta: Int64 = direction == .increment ? 5_000 : -5_000
            seek(min(max(0, positionMs + delta), durationMs))
        }
        .onChange(of: canSeek) { _, enabled in if !enabled { scrub = nil; rejectedGesture = true } }
        .onChange(of: gestureActive) { _, active in if !active { scrub = nil; rejectedGesture = false } }
    }
}

private nonisolated struct RingHitShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path(ellipseIn: rect.insetBy(dx: -14, dy: -14))
        path.addEllipse(in: rect.insetBy(dx: 14, dy: 14))
        return path
    }
}

func playbackTime(_ milliseconds: Int64) -> String {
    let seconds = max(0, milliseconds / 1000)
    return String(format: "%lld:%02lld", seconds / 60, seconds % 60)
}

nonisolated struct PlaybackClockSchedule: TimelineSchedule {
    var running: Bool
    var reducedMotion: Bool
    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnySequence<Date> {
        guard running else { return AnySequence([startDate]) }
        return AnySequence(PeriodicTimelineSchedule(from: startDate, by: reducedMotion ? 1 : 1.0 / 30).entries(from: startDate, mode: mode))
    }
}
