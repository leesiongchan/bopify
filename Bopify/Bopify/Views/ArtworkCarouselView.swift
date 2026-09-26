import SwiftUI
import os
import BopifyDomain
import BopifyPlayback

struct ArtworkCarouselView: View {
    let queue: PlaybackQueue?
    let currentTrack: Track?
    let image: Image?
    let store: ArtworkStore
    let artworkNamespace: Namespace.ID
    var canNext = false
    var next: () -> Void = {}
    @GestureState private var albumDrag = AlbumDragState()
    @State private var dragOccurrenceID: [String?]?
    @State private var rejectedAlbumGesture = false
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
                    ArtworkView(image: image, diameter: 204 * scale * albumScale)
                        .modifier(CurrentArtworkMatch(namespace: artworkNamespace, active: true))
                        .position(x: center.x + albumOffset.width, y: center.y + albumOffset.height)
                }
                TimelineView(.animation(paused: !animating)) { context in
                    let progress: CGFloat = animating ? fraction(at: context.date) : 1
                    ZStack {
                    ForEach(layers) { layer in
                        artworkLayer(layer, progress: progress, scale: scale, center: center)
                    }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
                Color.clear.frame(width: 204 * scale, height: 204 * scale)
                    .contentShape(Circle())
                    .gesture(albumGesture(diameter: 204 * scale))
                    .position(center)
                    .accessibilityHidden(true)
            }
            .animation(.spring(duration: reduceMotion ? 0.12 : 0.24, bounce: 0.16), value: albumHeld)
        }
        .frame(height: 340)
        .onAppear { retarget() }
        .onChange(of: albumDrag.isHeld) { _, held in
            if !held { dragOccurrenceID = nil; rejectedAlbumGesture = false }
        }
        .onChange(of: canNext) { _, enabled in
            if !enabled && albumDrag.isHeld { rejectedAlbumGesture = true }
        }
        .onChange(of: queue) { _, _ in retarget() }
        .onChange(of: currentTrack) { _, _ in retarget() }
        .task(id: generation) {
            let version = generation
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 160 : 420))
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

    private func artworkLayer(_ layer: ArtworkLayer, progress: CGFloat, scale: CGFloat, center: CGPoint) -> some View {
        let point = layer.point(at: progress)
        let size = layer.fromSize + (layer.toSize - layer.fromSize) * progress
        let diameter = size * scale * (layer.isCurrent ? albumScale : 1)
        let offset = layer.isCurrent ? albumOffset : CGSize(
            width: point.x < 0 ? min(0, albumOffset.width) : max(0, albumOffset.width), height: 0)
        let position = CGPoint(x: center.x + point.x * scale + offset.width,
                               y: center.y + point.y * scale + offset.height)
        return ArtworkView(image: artwork(for: layer), diameter: diameter)
            .modifier(SideArtworkGlass(active: !layer.isCurrent))
            .modifier(CurrentArtworkMatch(namespace: artworkNamespace, active: layer.isCurrent))
            .position(position)
            .opacity(layer.fromOpacity + (layer.toOpacity - layer.fromOpacity) * progress)
            .zIndex(layer.isCurrent ? 2 : 1)
    }

    private var occurrenceID: [String?] { [currentTrack?.uri.rawValue, queue?.current?.id] }
    private var albumHeld: Bool { canNext && !rejectedAlbumGesture && albumDrag.isHeld && dragOccurrenceID == occurrenceID }
    private var albumScale: CGFloat { albumHeld ? 0.94 : 1 }
    private var albumOffset: CGSize {
        guard albumHeld else { return .zero }
        let x = albumDrag.translation.width
        return CGSize(width: 120 * tanh(x / 120), height: albumDrag.translation.height * 0.15)
    }

    private func albumGesture(diameter: CGFloat) -> some Gesture {
        LongPressGesture(minimumDuration: 0.25, maximumDistance: 10)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .updating($albumDrag) { value, state, _ in
                if case let .second(true, drag) = value {
                    state.isHeld = true
                    state.translation = drag?.translation ?? .zero
                }
            }
            .onChanged { value in
                if case .second(true, _) = value, dragOccurrenceID == nil, canNext {
                    dragOccurrenceID = occurrenceID
                    BopifyLog.playback.debug("album drag activated")
                }
            }
            .onEnded { value in
                defer { dragOccurrenceID = nil; rejectedAlbumGesture = false }
                guard canNext, !rejectedAlbumGesture, dragOccurrenceID == occurrenceID,
                      case let .second(true, drag?) = value,
                      shouldAdvanceAlbum(translation: drag.translation, diameter: diameter) else { return }
                BopifyLog.playback.debug("album drag advancing to next")
                next()
            }
    }

    private var artworkURLs: [URL] { layers.compactMap { $0.entry.track?.artwork?.url } }

    private func artwork(for layer: ArtworkLayer) -> Image? {
        if let url = layer.entry.track?.artwork?.url, let loaded = store.images[url] { return Image(nsImage: loaded) }
        return layer.isCurrent ? image : nil
    }

    private func fraction(at date: Date) -> CGFloat {
        let t = min(1, max(0, date.timeIntervalSince(started) / (reduceMotion ? 0.16 : 0.42)))
        return reduceMotion ? t : (1 - (1 + 8 * t) * exp(-8 * t)) / (1 - 9 * exp(-8))
    }

    private func retarget() {
        guard let queue, var current = queue.current,
              current.uri == currentTrack?.uri else { return }
        if current.track == nil { current.track = currentTrack }
        let initial = layers.isEmpty && previousQueue == nil
        let desired: [(QueueEntry, CGPoint, CGFloat)] = [
            queue.previous.last.map { ($0, CGPoint(x: -140, y: 0), 64) },
            (current, .zero, 204),
            queue.next.first.map { ($0, CGPoint(x: 140, y: 0), 64) }
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
            let old = layers.first { $0.id == entry.id && $0.isCurrent == (entry.id == current.id) }
            let start = travel && old?.to == target ? old?.point(at: progress) ?? target : target
            let oldSize = old.map { $0.fromSize + ($0.toSize - $0.fromSize) * progress }
            return ArtworkLayer(entry: entry, from: start, to: target,
                fromSize: travel ? oldSize ?? size : size, toSize: size,
                fromOpacity: old == nil ? (initial ? 1 : 0) : old!.fromOpacity + (old!.toOpacity - old!.fromOpacity) * progress,
                toOpacity: 1, isCurrent: entry.id == current.id)
        }
        for old in layers where !ids.contains(old.id) && !old.isCurrent {
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
        let t = min(1, max(0, progress))
        return CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
    }
}

private struct AlbumDragState {
    var isHeld = false
    var translation = CGSize.zero
}

private struct SideArtworkGlass: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        if active && !reduceTransparency {
            if #available(macOS 26.0, *) {
                content.opacity(0.6).glassEffect(.clear, in: Circle())
            } else {
                content.opacity(0.6).background(.ultraThinMaterial, in: Circle())
            }
        } else { content }
    }
}

struct DiscView: View {
    let diameter: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        Group {
            if reduceTransparency || contrast == .increased {
                Circle().fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(Circle().strokeBorder(.primary.opacity(0.5), lineWidth: 1))
            } else if #available(macOS 26.0, *) {
                Color.clear.glassEffect(.clear, in: Circle())
            } else {
                Circle().fill(.ultraThinMaterial)
                    .overlay(Circle().strokeBorder(.primary.opacity(0.18), lineWidth: 1))
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}
