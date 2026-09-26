import SwiftUI
import os
import BopifyDomain
import BopifyPlayback

struct RadialProgressView: View {
    let positionMs: Int64
    let durationMs: Int64
    let canSeek: Bool
    var remainingTimeOffset: CGFloat = 18
    let seek: (Int64) -> Void
    @State private var scrub: RadialScrub?
    @State private var lastScrubProgress = 0.0
    @State private var holdTask: Task<Void, Never>?
    @State private var pressOrigin: CGPoint?
    @State private var rejectedGesture = false
    @GestureState private var gestureActive = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    private var progress: Double {
        scrub?.progress ?? (durationMs > 0 ? min(1, max(0, Double(positionMs) / Double(durationMs))) : 0)
    }
    private var displayedPosition: Int64 { seekPosition(progress: progress, durationMs: durationMs) ?? 0 }

    var body: some View {
        GeometryReader { geometry in
            let radius = geometry.size.width / 2
            let angle = (scrub?.progress ?? lastScrubProgress) * .pi * 2 + .pi / 2
            ZStack {
                Circle().stroke(.primary.opacity(contrast == .increased ? 0.45 : 0.12), lineWidth: 1)
                Circle().trim(from: 0, to: progress)
                    .stroke(.primary.opacity(0.65), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(90))
                Circle().fill(.white)
                    .frame(width: 22, height: 22)
                    .shadow(color: .black.opacity(0.16), radius: 5, y: 2)
                    .scaleEffect(scrub == nil ? 0.35 : 1)
                    .opacity(scrub == nil ? 0 : 1)
                    .animation(.spring(duration: reduceMotion ? 0.12 : 0.2, bounce: 0.12), value: scrub != nil)
                    .position(x: radius + cos(angle) * radius, y: radius + sin(angle) * radius)
                    .allowsHitTesting(false)
            }
            .contentShape(RingHitShape(), eoFill: true)
            .gesture(DragGesture(minimumDistance: 0)
                .updating($gestureActive) { _, state, _ in state = true }
                .onChanged { value in
                    guard canSeek, durationMs > 0, !rejectedGesture else { return }
                    let x = value.location.x - radius, y = value.location.y - radius
                    guard let fraction = radialProgress(x: x, y: y) else { return }
                    if scrub != nil {
                        scrub?.update(fraction)
                    } else if let origin = pressOrigin {
                        if hypot(value.location.x - origin.x, value.location.y - origin.y) > 10 {
                            cancelScrub()
                            rejectedGesture = true
                        }
                    } else {
                        guard abs(hypot(x, y) - radius) <= 18 else { rejectedGesture = true; return }
                        pressOrigin = value.location
                        holdTask = Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(250))
                            guard !Task.isCancelled else { return }
                            scrub = RadialScrub(start: fraction)
                            BopifyLog.playback.debug("radial scrub activated")
                        }
                    }
                }
                .onEnded { _ in
                    if canSeek, let scrub, let target = seekPosition(progress: scrub.progress, durationMs: durationMs) {
                        seek(target)
                        BopifyLog.playback.debug("radial scrub committed")
                    }
                    cancelScrub()
                    rejectedGesture = false
                })
            .overlay(alignment: .bottom) {
                Text("−" + playbackTime(max(0, durationMs - displayedPosition)))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .offset(y: remainingTimeOffset + 18)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("player.progress"))
        .accessibilityValue(Text("−" + playbackTime(max(0, durationMs - displayedPosition))))
        .accessibilityAdjustableAction { direction in
            guard canSeek, durationMs > 0 else { return }
            let delta: Int64 = direction == .increment ? 5_000 : -5_000
            seek(min(max(0, positionMs + delta), durationMs))
        }
        .onChange(of: canSeek) { _, enabled in
            if !enabled { cancelScrub(); rejectedGesture = gestureActive }
        }
        .onChange(of: durationMs) { _, _ in cancelScrub(); rejectedGesture = gestureActive }
        .onChange(of: gestureActive) { _, active in
            if !active { cancelScrub(); rejectedGesture = false }
        }
        .onDisappear { cancelScrub() }
    }

    private func cancelScrub() {
        holdTask?.cancel()
        holdTask = nil
        pressOrigin = nil
        if let scrub { lastScrubProgress = scrub.progress }
        scrub = nil
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
