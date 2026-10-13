import Carbon.HIToolbox
import SwiftUI
import os
import BopifyDomain
import BopifyLibrary
import BopifyPlayback

/// The empty and error copy that differs between library tabs.
struct CoverFlowCopy {
    let permission: LocalizedStringKey
    let enable: LocalizedStringKey
    let empty: LocalizedStringKey
    let unavailable: LocalizedStringKey
    let loading: LocalizedStringKey

    static var liked: Self { .init(permission: "library.permission", enable: "library.enable", empty: "library.empty", unavailable: "library.unavailable", loading: "library.loading") }
    static var recents: Self { .init(permission: "history.permission", enable: "history.enable", empty: "recents.empty", unavailable: "recents.unavailable", loading: "recents.loading") }
    static var explore: Self { .init(permission: "history.permission", enable: "history.enable", empty: "explore.empty", unavailable: "explore.unavailable", loading: "explore.loading") }
}

/// Counts this view in `source`'s reveals only once its reveal has run, so a task cancelled before it starts
/// neither hides another view's reveal nor leaves one behind.
struct RevealWhileShown<Source: CoverFlowSource>: ViewModifier {
    let source: Source
    @State private var revealed = false

    func body(content: Content) -> some View {
        content
            .task {
                guard !Task.isCancelled else { return }
                revealed = true
                await source.reveal(at: Date())
            }
            .onDisappear {
                guard revealed else { return }
                revealed = false
                source.hide(at: Date())
            }
    }
}

extension CoverFlowView where Accessory == EmptyView {
    init(model: Source, copy: CoverFlowCopy, artworkStore: ArtworkStore, onPlay: @escaping (Track) -> Void,
         onEnable: @escaping @MainActor () async -> Void) {
        self.init(model: model, copy: copy, artworkStore: artworkStore, onPlay: onPlay, onEnable: onEnable) { EmptyView() }
    }
}

struct CoverFlowView<Source: CoverFlowSource, Accessory: View>: View {
    let model: Source
    let copy: CoverFlowCopy
    let artworkStore: ArtworkStore
    let onPlay: (Track) -> Void
    let onEnable: @MainActor () async -> Void
    /// Follows the artist line, or sits under an empty shelf's message, such as Explore's station menu.
    @ViewBuilder let accessory: () -> Accessory
    @Environment(AppEnvironment.self) private var environment: AppEnvironment?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Position in covers, driven directly while dragging or scrolling and by the spring after release.
    @State private var spring = CoverFlowSpring(position: 0, velocity: 0, target: 0)
    @State private var isAnimating = false
    @State private var gestureOrigin: Double?
    @State private var scrollTravel = 0.0
    @State private var velocity = CoverFlowVelocity()
    private var selectedIndex: Int { model.tracks.firstIndex { $0.uri == model.selectedURI } ?? 0 }
    private var selectedTrack: Track? { model.tracks.indices.contains(selectedIndex) ? model.tracks[selectedIndex] : nil }

    var body: some View {
        GeometryReader { available in
        VStack(spacing: 3) {
            if model.tracks.isEmpty {
                VStack(spacing: 8) { emptyState; accessory() }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geometry in
                    let reach = max(2, geometry.size.width / 2 / CoverFlowMotion.spacing)
                    // Covers faint enough to sit near the edge aren't click targets.
                    let radius = max(1, Int(reach - 0.5))
                    ZStack {
                        ForEach(visibleIndices(reach: reach), id: \.self) { index in
                            let track = model.tracks[index]
                            let distance = Double(index) - spring.position
                            let placement = CoverFlowMotion.transform(distance: distance, reduceMotion: reduceMotion, reach: reach)
                            Button { activate(index) } label: { cover(for: track) }
                                .buttonStyle(.plain)
                                .frame(width: 76, height: 76)
                                .scaleEffect(placement.scale)
                                .rotation3DEffect(.degrees(placement.rotation), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
                                .opacity(placement.opacity)
                                .offset(x: placement.offset)
                                .zIndex(placement.zIndex)
                                .accessibilityLabel(Text(label(for: track)))
                                .accessibilityValue(Text(index == selectedIndex ? "library.selected" : ""))
                                .accessibilityAction(named: Text("library.play")) { onPlay(track) }
                                .help(label(for: track))
                                .task(id: ArtworkLoadRequest(url: track.artwork?.url, retryRevision: artworkStore.retryRevision)) {
                                    if let url = track.artwork?.url { await artworkStore.load(url) }
                                }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay {
                        CoverFlowInput(isAnimating: isAnimating, onPress: catchMotion, onClick: { x, width in
                            if let relative = coverFlowRelativeIndex(x: x - width / 2, radius: radius) { activate(selectedIndex + relative) }
                        }, onDrag: { translation, time in
                            if gestureOrigin == nil { beginGesture() }
                            move(to: (gestureOrigin ?? spring.position) - translation / CoverFlowMotion.spacing, at: time)
                        }, onRelease: release(at:), onSnap: { settle(on: Int(spring.position.rounded()), velocity: 0) },
                        onScroll: scroll, onFrame: { dt in
                            spring.step(dt: dt, reduceMotion: reduceMotion)
                            if spring.isSettled { isAnimating = false }
                        }, onNavigate: { navigate(by: $0) }, onPlay: { if let selectedTrack { onPlay(selectedTrack) } })
                        .frame(width: min(geometry.size.width, Double(radius * 2) * CoverFlowMotion.spacing + 76))
                        .accessibilityHidden(true)
                    }
                }
                .frame(height: max(44, min(88, available.size.height - 31)))
                .scaleEffect(min(1, max(0.6, (available.size.height - 31) / 88)))
                .overlay(alignment: .topTrailing) { status }
                if let selectedTrack {
                    VStack(spacing: 1) {
                        Text(selectedTrack.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                        HStack(spacing: 4) {
                            Text(selectedTrack.artists.map(\.name).joined(separator: ", "))
                                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                            accessory()
                        }
                    }.help(label(for: selectedTrack))
                }
            }
        }
        // Covers every gap around the covers and title; the covers' input view sits above it.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(PlayerBackgroundDragRegion())
        .modifier(RevealWhileShown(source: model))
        .task(id: model.selectedURI) {
            if let uri = model.selectedURI { await model.loadMoreIfNeeded(near: uri) }
        }
        .onAppear { jump(to: selectedIndex) }
        .onChange(of: model.tracks.isEmpty) { _, empty in if !empty { jump(to: selectedIndex) } }
        // Selection changed elsewhere (list refresh, restored selection): follow it.
        .onChange(of: selectedIndex) { _, index in
            guard gestureOrigin == nil, index != Int(spring.target.rounded()) else { return }
            if model.tracks.count <= 1 { jump(to: index) } else { settle(on: index) }
        }
        }
    }

    func visibleIndices(reach: Double) -> [Int] {
        guard !model.tracks.isEmpty else { return [] }
        let center = min(model.tracks.count - 1, max(0, Int(spring.position.rounded())))
        let radius = Int(reach.rounded(.up))
        return Array(max(0, center - radius)...min(model.tracks.count - 1, center + radius))
    }
    private func label(for track: Track) -> String {
        ([track.title] + track.artists.map(\.name)).joined(separator: " · ")
    }
    private func activate(_ index: Int) {
        guard model.tracks.indices.contains(index) else { return }
        if index == selectedIndex && !isAnimating { onPlay(model.tracks[index]) }
        else { settle(on: index) }
    }
    private func navigate(by delta: Int) {
        settle(on: Int(spring.target.rounded()) + delta)
    }

    private func jump(to index: Int) {
        spring = CoverFlowSpring(position: Double(index), velocity: 0, target: Double(index))
        isAnimating = false
    }
    /// Springs to a cover, keeping the current velocity so a new target redirects motion instead of restarting it.
    private func settle(on index: Int, velocity: Double? = nil) {
        guard !model.tracks.isEmpty else { return }
        let index = min(model.tracks.count - 1, max(0, index))
        spring.target = Double(index)
        if let velocity { spring.velocity = reduceMotion ? 0 : velocity }
        isAnimating = !spring.isSettled
        if model.tracks[index].uri != model.selectedURI { model.select(model.tracks[index].uri) }
    }
    /// Stops the covers where they are; returns whether they were moving so a catching tap doesn't also select.
    private func catchMotion() -> Bool {
        let wasMoving = isAnimating
        spring = CoverFlowSpring(position: spring.position, velocity: 0, target: spring.position)
        isAnimating = false
        return wasMoving
    }
    private func beginGesture() {
        _ = catchMotion()
        gestureOrigin = spring.position
        scrollTravel = 0
        velocity.reset()
    }
    private func move(to raw: Double, at time: TimeInterval) {
        let position = CoverFlowMotion.rubberBanded(raw, count: model.tracks.count)
        spring = CoverFlowSpring(position: position, velocity: 0, target: position)
        velocity.add(position: position, at: time)
        let index = min(model.tracks.count - 1, max(0, Int(position.rounded())))
        if model.tracks.indices.contains(index), model.tracks[index].uri != model.selectedURI { model.select(model.tracks[index].uri) }
    }
    private func release(at time: TimeInterval) {
        velocity.add(position: spring.position, at: time)
        let fling = velocity.velocity
        gestureOrigin = nil
        BopifyLog.library.debug("cover flow released velocity=\(fling, privacy: .public)")
        settle(on: CoverFlowMotion.restingIndex(position: spring.position, velocity: fling, count: model.tracks.count), velocity: fling)
    }
    private func scroll(_ input: CoverFlowScroll) {
        guard !model.tracks.isEmpty else { return }
        switch input {
        case let .wheel(delta):
            settle(on: CoverFlowMotion.wheelTarget(from: Int(spring.target.rounded()), delta: delta, count: model.tracks.count))
        case let .glide(delta):
            guard gestureOrigin == nil else { return }
            spring.target = CoverFlowMotion.glideTarget(from: spring.target, delta: delta, count: model.tracks.count)
            isAnimating = !spring.isSettled
            let index = Int(spring.target.rounded())
            if model.tracks[index].uri != model.selectedURI { model.select(model.tracks[index].uri) }
        case .glideEnded:
            guard gestureOrigin == nil else { return }
            settle(on: Int(spring.target.rounded()))
        case let .began(time):
            beginGesture()
            velocity.add(position: spring.position, at: time)
        case let .changed(delta, time):
            if gestureOrigin == nil { beginGesture() }
            scrollTravel -= delta / CoverFlowMotion.spacing
            move(to: (gestureOrigin ?? spring.position) + scrollTravel, at: time)
        case let .ended(time):
            guard gestureOrigin != nil else { return }
            release(at: time)
        }
    }
    private func cover(for track: Track) -> some View {
        let face = Group {
            if let url = track.artwork?.url, let image = artworkStore.images[url] {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [.gray.opacity(0.3), .black.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note").font(.system(size: 22)).foregroundStyle(.white.opacity(0.65))
                }
            }
        }
        .frame(width: 76, height: 76)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        return face
        .shadow(color: .black.opacity(0.25), radius: 5, y: 4)
        .overlay(alignment: .bottom) {
            face.scaleEffect(x: 1, y: -1)
                .frame(height: 8, alignment: .top).clipped()
                .mask(LinearGradient(colors: [.white.opacity(0.2), .clear], startPoint: .top, endPoint: .bottom))
                .offset(y: 10).accessibilityHidden(true)
        }
    }
    /// Loading and retry for a shelf that already shows covers; an empty shelf shows them in `emptyState`.
    private var status: some View {
        HStack(spacing: 4) {
            if model.isLoading { ProgressView().controlSize(.mini) }
            if model.error != nil {
                TimelineView(.periodic(from: .now, by: 1)) { context in retryButton(at: context.date) }
            }
        }
    }
    @ViewBuilder private var emptyState: some View {
        if model.isLoading {
            ProgressView { Text(copy.loading) }.controlSize(.small)
        } else if model.error == .authorizationRequired {
            VStack(spacing: 8) {
                Text(copy.permission).font(.caption).foregroundStyle(.secondary)
                Button(copy.enable) { Task { await onEnable() } }
                    .disabled(environment?.isEnablingLibrary == true)
                if let notice = environment?.libraryAuthorizationNotice { Text(notice).font(.caption) }
            }
        } else if model.error != nil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = model.retryAfter.map { max(0, Int(ceil($0.timeIntervalSince(context.date)))) } ?? 0
                VStack(spacing: 8) {
                    if case .some(.quotaExceeded) = model.error {
                        Text("library.quotaExceeded")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(model.retryAfter == nil ? copy.unavailable : "library.rateLimited")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if remaining > 0 { Text("library.retryIn \(remaining)").font(.caption).foregroundStyle(.secondary) }
                    retryButton(at: context.date)
                }
            }
        } else if model.hasMore {
            VStack(spacing: 8) {
                Text("library.skipped").font(.caption).foregroundStyle(.secondary)
                Button("library.more") { Task { await model.loadMore() } }
            }
        } else {
            Text(copy.empty).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func retryButton(at date: Date) -> some View {
        Button("library.retry") { Task { await model.retry(at: Date()) } }
            .font(.caption)
            .disabled(model.isLoading || model.retryAfter.map { $0 > date } == true)
    }
}

enum CoverFlowScroll {
    /// A mouse wheel notch: no phases, no precise deltas.
    case wheel(Double)
    /// A smoothed wheel's precise but phase-less delta, and the pause after the last one.
    case glide(Double)
    case glideEnded
    case began(TimeInterval)
    case changed(Double, TimeInterval)
    case ended(TimeInterval)
}

struct CoverFlowInput: NSViewRepresentable {
    var isAnimating: Bool
    /// Returns whether it caught covers in motion.
    var onPress: () -> Bool
    var onClick: (_ x: Double, _ width: Double) -> Void
    var onDrag: (_ translation: Double, _ time: TimeInterval) -> Void
    var onRelease: (TimeInterval) -> Void
    var onSnap: () -> Void
    var onScroll: (CoverFlowScroll) -> Void
    var onFrame: (_ dt: Double) -> Void
    var onNavigate: (Int) -> Void
    var onPlay: () -> Void
    func makeNSView(context: Context) -> InputView { InputView() }
    func updateNSView(_ view: InputView, context: Context) {
        view.input = self
        view.setAnimating(isAnimating)
    }
    final class InputView: NSControl, PlayerShortcutForwarding {
        var input: CoverFlowInput?
        private var origin: CGPoint?
        private var didDrag = false
        private var caughtMotion = false
        private var link: CADisplayLink?
        private var lastFrame: CFTimeInterval?
        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        // The spring runs on the display link so a grab reads the covers' true position mid-flight.
        func setAnimating(_ animating: Bool) {
            guard let link else { return }
            if animating && link.isPaused { lastFrame = nil }
            link.isPaused = !animating
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            link?.invalidate()
            link = nil
            guard window != nil else { return }
            let next = displayLink(target: self, selector: #selector(frame(_:)))
            next.isPaused = !(input?.isAnimating ?? false)
            next.add(to: .main, forMode: .common)
            link = next
        }
        @objc private func phaselessScrollEnded() {
            input?.onScroll(.glideEnded)
        }
        @objc private func frame(_ link: CADisplayLink) {
            let dt = lastFrame.map { link.timestamp - $0 } ?? link.duration
            lastFrame = link.timestamp
            input?.onFrame(min(dt, 1.0 / 30))
        }

        override func mouseDown(with event: NSEvent) {
            window?.makeKey()
            window?.makeFirstResponder(self)
            origin = convert(event.locationInWindow, from: nil)
            didDrag = false
            caughtMotion = input?.onPress() ?? false
        }
        override func mouseDragged(with event: NSEvent) {
            guard let origin else { return }
            let point = convert(event.locationInWindow, from: nil)
            guard didDrag || hypot(point.x - origin.x, point.y - origin.y) > 4 else { return }
            didDrag = true
            input?.onDrag(point.x - origin.x, event.timestamp)
        }
        override func mouseUp(with event: NSEvent) {
            if didDrag { input?.onRelease(event.timestamp) }
            // A tap that stops moving covers only settles them, like catching a scroll view.
            else if caughtMotion { input?.onSnap() }
            else if origin != nil { input?.onClick(convert(event.locationInWindow, from: nil).x, bounds.width) }
            origin = nil; didDrag = false; caughtMotion = false
        }
        override func scrollWheel(with event: NSEvent) {
            // Our own spring replaces the system's momentum so scrolling and dragging feel identical.
            guard event.momentumPhase.isEmpty else { return }
            let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
            guard event.hasPreciseScrollingDeltas else { input?.onScroll(.wheel(delta)); return }
            // Smoothed wheels (e.g. Logi Options+) send large precise deltas with no gesture phases and no ended
            // event: glide toward them and settle once the events stop.
            if event.phase.isEmpty {
                input?.onScroll(.glide(delta))
                NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(phaselessScrollEnded), object: nil)
                perform(#selector(phaselessScrollEnded), with: nil, afterDelay: 0.12)
                return
            }
            if event.phase.contains(.began) { input?.onScroll(.began(event.timestamp)) }
            if event.phase.contains(.changed) { input?.onScroll(.changed(delta, event.timestamp)) }
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) { input?.onScroll(.ended(event.timestamp)) }
        }
        override func keyDown(with event: NSEvent) {
            guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { window?.keyDown(with: event); return }
            switch Int(event.keyCode) {
            case kVK_LeftArrow: input?.onNavigate(-1)
            case kVK_RightArrow: input?.onNavigate(1)
            case kVK_Return, kVK_ANSI_KeypadEnter: if !event.isARepeat { input?.onPlay() }
            default: window?.keyDown(with: event)
            }
        }
    }
}

func coverFlowRelativeIndex(x: Double, radius: Int) -> Int? {
    guard x.isFinite else { return nil }
    if abs(x) <= 38 { return 0 }
    let sideHalfWidth = 76 * 0.8 * cos(48 * .pi / 180) / 2
    for distance in 1...max(1, radius) where distance <= radius {
        let index = x < 0 ? -distance : distance
        if abs(x - Double(index) * 44) <= sideHalfWidth { return index }
    }
    return nil
}
