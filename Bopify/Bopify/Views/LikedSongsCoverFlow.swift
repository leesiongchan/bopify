import Carbon.HIToolbox
import SwiftUI
import BopifyDomain
import BopifyLibrary
import BopifyPlayback

struct LikedSongsCoverFlow: View {
    let model: LikedSongsModel
    let artworkStore: ArtworkStore
    let onPlay: (Track) -> Void
    @Environment(AppEnvironment.self) private var environment: AppEnvironment?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragOffset = 0.0
    @State private var dragStart: Int?
    @State private var wheelOffset = 0.0
    private let spacing = 44.0
    private var selectedIndex: Int { model.tracks.firstIndex { $0.uri == model.selectedURI } ?? 0 }
    private var selectedTrack: Track? { model.tracks.indices.contains(selectedIndex) ? model.tracks[selectedIndex] : nil }

    var body: some View {
        GeometryReader { available in
        VStack(spacing: 3) {
            HStack {
                Text("library.title").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                if model.isLoading && !model.tracks.isEmpty { ProgressView().controlSize(.mini) }
                if model.error != nil && !model.tracks.isEmpty {
                    TimelineView(.periodic(from: .now, by: 1)) { context in retryButton(at: context.date) }
                }
            }
            .background(PlayerBackgroundDragRegion())
            if model.tracks.isEmpty {
                emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geometry in
                    let radius = geometry.size.width < 300 ? 1 : 2
                    ZStack {
                        ForEach(visibleIndices(radius: radius).map { model.tracks[$0] }, id: \.uri) { track in
                            let distance = (model.tracks.firstIndex { $0.uri == track.uri } ?? selectedIndex) - selectedIndex
                            Button {
                                if let index = model.tracks.firstIndex(where: { $0.uri == track.uri }) { activate(index) }
                            } label: { cover(for: track) }
                                .buttonStyle(.plain)
                                .frame(width: 76, height: 76)
                                .scaleEffect(distance == 0 ? 1 : 0.8)
                                .rotation3DEffect(.degrees(reduceMotion ? 0 : Double(distance.signum()) * -48),
                                                  axis: (x: 0, y: 1, z: 0), perspective: 0.6)
                                .opacity(abs(distance) == 2 ? 0.55 : 1)
                                .offset(x: Double(distance) * spacing + dragOffset)
                                .zIndex(Double(3 - abs(distance)))
                                .accessibilityLabel(Text(label(for: track)))
                                .accessibilityValue(Text(distance == 0 ? "library.selected" : ""))
                                .accessibilityAction(named: Text("library.play")) { onPlay(track) }
                                .help(label(for: track))
                                .task(id: track.artwork?.url) {
                                    if let url = track.artwork?.url { await artworkStore.load(url) }
                                }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay {
                        CoverFlowInput(onClick: { x, width in
                            if let relative = coverFlowRelativeIndex(x: x - width / 2, radius: radius) { activate(selectedIndex + relative) }
                        }, onDrag: { translation in
                            guard !model.tracks.isEmpty else { return }
                            if dragStart == nil { dragStart = selectedIndex }
                            let start = dragStart ?? selectedIndex
                            let index = min(model.tracks.count - 1, max(0, start - Int((translation / spacing).rounded())))
                            model.select(model.tracks[index].uri)
                            dragOffset = min(spacing, max(-spacing, translation + Double(index - start) * spacing))
                        }, onDragEnd: {
                            withAnimation(.easeOut(duration: reduceMotion ? 0.12 : 0.28)) { dragOffset = 0; dragStart = nil }
                        }, onScroll: { delta in
                            wheelOffset += delta
                            if abs(wheelOffset) >= 24 {
                                navigate(by: wheelOffset < 0 ? 1 : -1)
                                wheelOffset = 0
                            }
                        }, onNavigate: { navigate(by: $0) }, onPlay: { if let selectedTrack { onPlay(selectedTrack) } })
                        .frame(width: min(geometry.size.width, Double(radius * 2) * spacing + 76))
                        .accessibilityHidden(true)
                    }
                }
                .frame(height: max(44, min(88, available.size.height - 46)))
                .scaleEffect(min(1, max(0.6, (available.size.height - 46) / 88)))
                if let selectedTrack {
                    VStack(spacing: 1) {
                        Text(selectedTrack.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                        Text(selectedTrack.artists.map(\.name).joined(separator: ", "))
                            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }.help(label(for: selectedTrack)).background(PlayerBackgroundDragRegion())
                }
            }
        }
        .task {
            guard !Task.isCancelled else { return }
            await model.reveal(at: Date())
        }
        .task(id: model.selectedURI) {
            if let uri = model.selectedURI { await model.loadMoreIfNeeded(near: uri) }
        }
        .onDisappear { model.hide(at: Date()) }
        }
    }

    func visibleIndices(radius: Int) -> [Int] {
        guard !model.tracks.isEmpty else { return [] }
        return Array(max(0, selectedIndex - radius)...min(model.tracks.count - 1, selectedIndex + radius))
    }
    private func label(for track: Track) -> String {
        ([track.title] + track.artists.map(\.name)).joined(separator: " · ")
    }
    private func activate(_ index: Int) {
        guard model.tracks.indices.contains(index) else { return }
        if index == selectedIndex { onPlay(model.tracks[index]) }
        else { navigate(by: index - selectedIndex) }
    }
    private func navigate(by delta: Int) {
        guard !model.tracks.isEmpty else { return }
        let index = min(model.tracks.count - 1, max(0, selectedIndex + delta))
        withAnimation(.easeOut(duration: reduceMotion ? 0.12 : 0.28)) { model.select(model.tracks[index].uri) }
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
    @ViewBuilder private var emptyState: some View {
        if model.isLoading {
            ProgressView { Text("library.loading") }.controlSize(.small)
        } else if model.error == .authorizationRequired {
            VStack(spacing: 8) {
                Text("library.permission").font(.caption).foregroundStyle(.secondary)
                Button("library.enable") { Task { await environment?.enableLikedSongs() } }
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
                        Text(model.retryAfter == nil ? "library.unavailable" : "library.rateLimited")
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
            Text("library.empty").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func retryButton(at date: Date) -> some View {
        Button("library.retry") { Task { await model.retry(at: Date()) } }
            .font(.caption)
            .disabled(model.isLoading || model.retryAfter.map { $0 > date } == true)
    }
}

struct CoverFlowInput: NSViewRepresentable {
    var onClick: (_ x: Double, _ width: Double) -> Void
    var onDrag: (Double) -> Void
    var onDragEnd: () -> Void
    var onScroll: (Double) -> Void
    var onNavigate: (Int) -> Void
    var onPlay: () -> Void
    func makeNSView(context: Context) -> InputView { InputView() }
    func updateNSView(_ view: InputView, context: Context) { view.input = self }
    final class InputView: NSControl, PlayerShortcutForwarding {
        var input: CoverFlowInput?
        private var origin: CGPoint?
        private var didDrag = false
        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            window?.makeKey()
            window?.makeFirstResponder(self)
            origin = convert(event.locationInWindow, from: nil)
            didDrag = false
        }
        override func mouseDragged(with event: NSEvent) {
            guard let origin else { return }
            let point = convert(event.locationInWindow, from: nil)
            guard didDrag || hypot(point.x - origin.x, point.y - origin.y) > 4 else { return }
            didDrag = true
            input?.onDrag(point.x - origin.x)
        }
        override func mouseUp(with event: NSEvent) {
            if didDrag { input?.onDragEnd() }
            else if origin != nil { input?.onClick(convert(event.locationInWindow, from: nil).x, bounds.width) }
            origin = nil; didDrag = false
        }
        override func scrollWheel(with event: NSEvent) {
            guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { super.scrollWheel(with: event); return }
            input?.onScroll(event.scrollingDeltaX)
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
