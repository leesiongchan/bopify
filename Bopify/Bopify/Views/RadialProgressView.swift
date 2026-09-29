import SwiftUI
import os
import BopifyDomain
import BopifyPlayback

struct RadialProgressView: View {
    let positionMs: Int64
    let durationMs: Int64
    let canSeek: Bool
    let onSeek: (Int64) -> Void
    var onInteractionChanged: (Bool) -> Void = { _ in }
    var isVisible = true
    var showsTime = true
    var isPointerEnabled = true
    @State private var scrub: RadialScrub?
    @State private var lastScrubProgress = 0.0
    @State private var holdTask: Task<Void, Never>?
    @State private var pressOrigin: CGPoint?
    @State private var isGestureRejected = false
    @GestureState private var isGestureActive = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    private var progress: Double {
        scrub?.progress ?? (durationMs > 0 ? min(1, max(0, Double(positionMs) / Double(durationMs))) : 0)
    }
    private var displayedPosition: Int64 { seekPosition(progress: progress, durationMs: durationMs) ?? 0 }

    var body: some View {
        GeometryReader { geometry in
            let radius = geometry.size.width / 2
            let angle = (scrub?.progress ?? lastScrubProgress) * .pi * 2 - .pi / 2
            ZStack {
                Circle().trim(from: 0.035, to: 0.965)
                    .stroke(.primary.opacity(contrast == .increased ? 0.45 : 0.12), lineWidth: 1)
                    .rotationEffect(.degrees(-90))
                Circle().trim(from: 0.035, to: max(0.035, min(0.965, progress)))
                    .stroke(.primary.opacity(0.65), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Circle().fill(.white)
                    .frame(width: 22, height: 22)
                    .shadow(color: .black.opacity(0.16), radius: 5, y: 2)
                    .scaleEffect(scrub == nil ? 0.35 : 1)
                    .opacity(scrub == nil ? 0 : 1)
                    .animation(.spring(duration: reduceMotion ? 0.12 : 0.2, bounce: 0.12), value: scrub != nil)
                    .position(x: radius + cos(angle) * radius, y: radius + sin(angle) * radius)
                    .allowsHitTesting(false)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .background {
                Circle()
                    .fill(RadialGradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .white.opacity(0.32), location: 0.28),
                        .init(color: .cyan.opacity(0.16), location: 0.65),
                        .init(color: .clear, location: 1)
                    ], center: .center, startRadius: radius * 204 / 274, endRadius: radius * 310 / 274))
                    .frame(width: radius * 2 * 310 / 274, height: radius * 2 * 310 / 274)
                    .opacity(scrub == nil ? 0 : 1)
                    .animation(.easeOut(duration: reduceMotion ? 0.12 : 0.2), value: scrub != nil)
                    .allowsHitTesting(false)
            }
            .contentShape(RingHitShape(), eoFill: true)
            .gesture(DragGesture(minimumDistance: 0)
                .updating($isGestureActive) { _, state, _ in state = true }
                .onChanged { value in
                    guard canSeek, isVisible, durationMs > 0, !isGestureRejected else { return }
                    let x = value.location.x - radius, y = value.location.y - radius
                    guard let fraction = radialProgress(x: x, y: y) else { return }
                    if scrub != nil {
                        scrub?.update(fraction)
                    } else if let origin = pressOrigin {
                        if hypot(value.location.x - origin.x, value.location.y - origin.y) > 10 {
                            cancelScrub()
                            isGestureRejected = true
                        }
                    } else {
                        guard abs(hypot(x, y) - radius) <= 18 else { isGestureRejected = true; return }
                        pressOrigin = value.location
                        onInteractionChanged(true)
                        holdTask = Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(250))
                            guard !Task.isCancelled else { return }
                            scrub = RadialScrub(start: fraction)
                            BopifyLog.playback.debug("radial scrub activated")
                        }
                    }
                }
                .onEnded { _ in
                    if canSeek, isVisible, let scrub, let target = seekPosition(progress: scrub.progress, durationMs: durationMs) {
                        onSeek(target)
                        BopifyLog.playback.debug("radial scrub committed")
                    }
                    cancelScrub()
                    isGestureRejected = false
                }, including: isPointerEnabled ? .all : .none)
            .overlay(alignment: .bottom) {
                if showsTime { Text("−" + playbackTime(max(0, durationMs - displayedPosition)))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .offset(y: 6)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("player.progress"))
        .accessibilityValue(Text("−" + playbackTime(max(0, durationMs - displayedPosition))))
        .accessibilityAdjustableAction { direction in
            guard canSeek, durationMs > 0 else { return }
            let delta: Int64 = direction == .increment ? 5_000 : -5_000
            onSeek(min(max(0, positionMs + delta), durationMs))
        }
        .onChange(of: canSeek) { _, enabled in
            if !enabled { cancelScrub(); isGestureRejected = isGestureActive }
        }
        .onChange(of: durationMs) { _, _ in cancelScrub(); isGestureRejected = isGestureActive }
        .onChange(of: isGestureActive) { _, active in
            if !active { cancelScrub(); isGestureRejected = false }
        }
        .onChange(of: isVisible) { _, visible in if !visible { cancelScrub(); isGestureRejected = isGestureActive } }
        .onDisappear { cancelScrub() }
    }

    private func cancelScrub() {
        if pressOrigin != nil || scrub != nil { onInteractionChanged(false) }
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
