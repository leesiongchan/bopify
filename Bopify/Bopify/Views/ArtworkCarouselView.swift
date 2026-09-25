import SwiftUI
import BopifyDomain
import BopifyPlayback

struct ArtworkCarouselView: View {
    let queue: PlaybackQueue?
    let currentTrack: Track?
    let image: Image?
    let store: ArtworkStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var layers: [ArtworkLayer] = []
    @State private var previousQueue: PlaybackQueue?
    @State private var started = Date.distantPast
    @State private var generation = 0
    @State private var animating = false

    var body: some View {
        GeometryReader { geometry in
            let scale = min(1, (geometry.size.width - 68) / 310)
            let center = CGPoint(x: geometry.size.width / 2, y: 165)
            ZStack {
                DiscView(diameter: 310 * scale).position(center)
                if layers.isEmpty {
                    ArtworkView(image: image, diameter: 204 * scale).position(center)
                }
                TimelineView(.animation(paused: !animating)) { context in
                    let progress: CGFloat = animating ? fraction(at: context.date) : 1
                    ZStack {
                    ForEach(layers) { layer in
                        let point = layer.point(at: progress)
                        let diameter = layer.fromSize + (layer.toSize - layer.fromSize) * progress
                        ArtworkView(image: artwork(for: layer), diameter: diameter * scale)
                            .position(x: center.x + point.x * scale, y: center.y + point.y * scale)
                            .opacity(layer.fromOpacity + (layer.toOpacity - layer.fromOpacity) * progress)
                            .zIndex(layer.isCurrent ? 2 : 1)
                    }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
        }
        .frame(height: 330)
        .onAppear { retarget() }
        .onChange(of: queue) { _, _ in retarget() }
        .onChange(of: currentTrack) { _, _ in retarget() }
        .task(id: generation) {
            let version = generation
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 160 : 720))
            guard !Task.isCancelled, version == generation else { return }
            layers.removeAll { $0.toOpacity == 0 }
            animating = false
        }
        .task(id: artworkURLs) {
            await withTaskGroup(of: Void.self) { group in
                for url in artworkURLs { group.addTask { await store.load(url) } }
            }
        }
    }

    private var artworkURLs: [URL] { layers.compactMap { $0.entry.track?.artwork?.url } }

    private func artwork(for layer: ArtworkLayer) -> Image? {
        if let url = layer.entry.track?.artwork?.url, let loaded = store.images[url] { return Image(nsImage: loaded) }
        return layer.isCurrent ? image : nil
    }

    private func fraction(at date: Date) -> CGFloat {
        let t = min(1, max(0, date.timeIntervalSince(started) / (reduceMotion ? 0.16 : 0.72)))
        return reduceMotion ? t : (1 - (1 + 8 * t) * exp(-8 * t)) / (1 - 9 * exp(-8))
    }

    private func retarget() {
        guard let queue, var current = queue.current,
              current.uri == currentTrack?.uri else { return }
        if current.track == nil { current.track = currentTrack }
        let initial = layers.isEmpty && previousQueue == nil
        let desired: [(QueueEntry, CGPoint, CGFloat)] = [
            queue.previous.last.map { ($0, CGPoint(x: -126, y: -112), 80) },
            (current, .zero, 204),
            queue.next.first.map { ($0, CGPoint(x: 126, y: 112), 80) }
        ].compactMap { $0 }
        let ids = desired.map { $0.0.id }
        if layers.filter({ $0.toOpacity == 1 }).map(\.id) == ids {
            for index in layers.indices {
                if let entry = desired.first(where: { $0.0.id == layers[index].id })?.0 { layers[index].entry = entry }
            }
            previousQueue = queue
            return
        }
        let now = Date.now
        let progress = fraction(at: now)
        let direction = carouselDirection(old: previousQueue, new: queue)
        let travel = !reduceMotion && direction != .fade
        var result: [ArtworkLayer] = desired.map { entry, target, size in
            let old = layers.first { $0.id == entry.id }
            let start = travel ? old?.point(at: progress) ?? target : target
            let oldSize = old.map { $0.fromSize + ($0.toSize - $0.fromSize) * progress }
            return ArtworkLayer(entry: entry, from: start, to: target,
                fromSize: travel ? oldSize ?? size : size, toSize: size,
                fromOpacity: old == nil ? (initial ? 1 : 0) : old!.fromOpacity + (old!.toOpacity - old!.fromOpacity) * progress,
                toOpacity: 1, isCurrent: entry.id == current.id)
        }
        for old in layers where !ids.contains(old.id) {
            result.append(ArtworkLayer(entry: old.entry, from: old.point(at: progress), to: old.point(at: progress),
                fromSize: old.fromSize + (old.toSize - old.fromSize) * progress,
                toSize: old.toSize, fromOpacity: old.fromOpacity + (old.toOpacity - old.fromOpacity) * progress,
                toOpacity: 0, isCurrent: false))
        }
        layers = result
        previousQueue = queue
        started = now
        generation += 1
        animating = !initial
    }
}

private struct ArtworkLayer: Identifiable {
    var entry: QueueEntry
    var from: CGPoint
    var to: CGPoint
    var fromSize: CGFloat
    var toSize: CGFloat
    var fromOpacity: CGFloat
    var toOpacity: CGFloat
    var isCurrent: Bool
    var id: String { entry.id }

    func point(at progress: CGFloat) -> CGPoint {
        let t = min(1, max(0, progress)), u = 1 - t
        let control = CGPoint(x: (from.x + to.x) / 2 - (to.y - from.y) * 0.13,
                              y: (from.y + to.y) / 2 + (to.x - from.x) * 0.13)
        return CGPoint(x: u*u*from.x + 2*u*t*control.x + t*t*to.x,
                       y: u*u*from.y + 2*u*t*control.y + t*t*to.y)
    }
}

struct DiscView: View {
    let diameter: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [Color(white: 0.105), Color(white: 0.045)], startPoint: .topLeading, endPoint: .bottomTrailing))
            ForEach([0.82, 0.91, 0.98], id: \.self) { scale in
                Circle().strokeBorder(.white.opacity(contrast == .increased ? 0.4 : 0.07), lineWidth: 0.6)
                    .padding(diameter * (1 - scale) / 2)
            }
            Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.3), .white.opacity(0.03), .white.opacity(0.13)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
        }
        .frame(width: diameter, height: diameter)
        .shadow(color: .black.opacity(0.35), radius: 20, y: 12)
        .accessibilityHidden(true)
    }
}
