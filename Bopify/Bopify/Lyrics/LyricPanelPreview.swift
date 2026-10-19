#if DEBUG
import AppKit
import Observation
import SwiftUI
import BopifyDomain
import BopifyPlayback

enum LyricPreviewFixture: String, CaseIterable {
    case timed, long, rtl, plain, instrumental, noMatch, failure, loading

    var content: LyricContent {
        switch self {
        case .plain: return .plain("The afternoon folds into green.\nLeave a little room for the rain.\nLet the quiet settle in.")
        case .instrumental: return .instrumental
        case .noMatch: return .noMatch
        case .failure: return .failure
        case .loading: return .loading
        default: break
        }
        let current: String = switch self {
        case .long: String(repeating: "Leave a little room for the rain, and a little room for the light beside the window. ", count: 24)
        case .rtl: "للنافذة ضوء هادئ\nوللصباح متسع جديد"
        default: "Leave a little room for the rain"
        }
        return .timed(try! LyricDocument(cues: [
            LyricCue(id: "opening", startMs: 10_000, text: "A room with time to spare"),
            LyricCue(id: "gap", startMs: 55_000, text: ""),
            LyricCue(id: "previous", startMs: 60_000, text: "The afternoon folds into green"),
            LyricCue(id: "current", startMs: 70_000, text: current),
            LyricCue(id: "next", startMs: 80_000, text: "Let the quiet settle in"),
            LyricCue(id: "last", startMs: 90_000, text: "There is light along the sill"),
        ]))
    }
}

@MainActor @Observable
final class LyricPanelPreviewSession {
    let model: LyricRibbonModel
    let environment = makePreviewEnvironment(.playing)
    private var songIndex = 0
    private(set) var fixture: LyricPreviewFixture = .timed
    private(set) var isClockRunning = false
    @ObservationIgnored private let now: () -> TimeInterval
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var clock: Task<Void, Never>?
    @ObservationIgnored private var clockGeneration: UInt64 = 0
    @ObservationIgnored private var basePosition: Int64 = 72_000
    @ObservationIgnored private var baseTime: TimeInterval
    @ObservationIgnored private var controlWindow: NSWindow?
    @ObservationIgnored private lazy var controller = PlayerWindowController(defaults: defaults)
    @ObservationIgnored private lazy var panel: StatusPanel = { @MainActor in
        let panel = StatusPanel(content: RecordPlayerView(player: environment.player!, artworkStore: environment.artworkStore,
            presentation: environment.presentation, windowController: controller, lyricModel: model,
            onLyricSeek: { [weak self] time, snapshot in
                guard let self, self.model.snapshot.occurrenceID == snapshot.occurrenceID else { return }
                self.advance(by: time - self.model.snapshot.positionMs, explicitSeek: true)
            }).environment(environment))
        panel.isReleasedWhenClosed = false
        panel.setFrame(CGRect(x: 500, y: 400, width: 484, height: 154), display: false)
        panel.onDismiss = { [weak self] in self?.hide() }
        panel.onPointerChanged = { [weak self] in self?.environment.presentation.sendAttention(.pointer($0)) }
        panel.onKeyChanged = { [weak self] in self?.environment.presentation.sendAttention(.keyboardFocus($0)) }
        panel.onTogglePlayback = { [weak self] in
            guard let self else { return }
            self.setPlaying(!self.model.snapshot.isPlaying)
        }
        panel.onWindowDragChanged = { [weak self] active in self?.controller.setDragging(active) }
        controller.attach(to: panel)
        return panel
    }()

    private func observeLayout() {
        withObservationTracking {
            controller.apply(mode: environment.presentation.mode, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                             showsLyrics: model.isVisible)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.model.isVisible else { return }
                self.observeLayout()
            }
        }
    }

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         defaults: UserDefaults = UserDefaults(suiteName: "com.leesiongchan.bopify.lyrics-preview")!) {
        self.now = now
        self.sleep = sleep
        self.defaults = defaults
        baseTime = now()
        model = LyricRibbonModel(snapshot: LyricPlaybackSnapshot(sessionID: UUID().uuidString,
            occurrenceID: UUID().uuidString, recordingID: "original-timed", title: "Window Seat", artist: "Soft Weather",
            positionMs: 72_000, durationMs: 100_000, isPlaying: true, seekRevision: 0, artworkURL: previewArtworkURL(0)))
        model.completeLoad(fixture.content, token: model.beginLoad(), source: fixtureSource)
    }

    func show() {
        synchronize()
        model.show()
        _ = panel
        environment.presentation.isVisible = true
        observeLayout()
        panel.orderFrontRegardless()
        startClock()
    }

    func hide() { stopClock(); model.hide(); panel.orderOut(nil); environment.presentation.isVisible = false }

    func setPlaying(_ playing: Bool) {
        synchronize()
        var input = model.snapshot
        input.isPlaying = playing && input.positionMs < input.durationMs
        model.update(input)
        anchorTime()
        if input.isPlaying { startClock() } else { stopClock() }
    }

    func advance(by milliseconds: Int64, explicitSeek: Bool) {
        synchronize()
        var input = model.snapshot
        let (position, overflow) = input.positionMs.addingReportingOverflow(milliseconds)
        input.positionMs = overflow ? (milliseconds > 0 ? input.durationMs : 0) : min(input.durationMs, max(0, position))
        if explicitSeek { input.seekRevision &+= 1 }
        if input.positionMs >= input.durationMs { input.isPlaying = false }
        model.update(input)
        anchorTime()
        if !input.isPlaying { stopClock() }
    }

    func selectFixture(_ fixture: LyricPreviewFixture) {
        self.fixture = fixture
        var input = model.snapshot
        input.occurrenceID = UUID().uuidString
        input.recordingID = "original-\(fixture.rawValue)"
        input.positionMs = 72_000
        model.update(input)
        model.completeLoad(fixture.content, token: model.beginLoad(), source: fixtureSource)
        anchorTime()
    }

    private var fixtureSource: LyricSourceMetadata? {
        switch fixture.content {
        case .timed, .plain:
            return LyricSourceMetadata(lyrics: TrackLyrics(trackURI: previewTracks[0].uri, synchronization: .lineSynced,
                lines: [], provider: "fixture", providerDisplayName: "Fixture provider", language: fixture == .rtl ? "ar" : "en",
                isRightToLeft: fixture == .rtl))
        default: return nil
        }
    }

    func changeSong(_ direction: CarouselDirection) {
        synchronize()
        songIndex = (songIndex + (direction == .previous ? 2 : 1)) % 3
        var input = model.snapshot
        input.occurrenceID = UUID().uuidString
        input.recordingID = "original-song-\(songIndex)"
        input.title = ["Window Seat", "After the Last Train", "Blue Hour Walk"][songIndex]
        input.artist = ["Soft Weather", "Sunday Radio", "Paper Lanterns"][songIndex]
        input.artworkURL = previewArtworkURL(songIndex)
        input.direction = direction
        input.positionMs = 72_000
        model.update(input)
        model.completeLoad(fixture.content, token: model.beginLoad(), source: fixtureSource)
        anchorTime()
    }

    func focusLyrics() { controller.focusLyrics() }

    func setExpanded(_ expanded: Bool) {
        environment.presentation.sendAttention(.pointer(false))
        environment.presentation.sendAttention(.keyboardFocus(expanded))
    }

    func shutdown() {
        hide()
        environment.player?.stop()
        controlWindow?.close()
        controlWindow = nil
    }

    func showControls() {
        if controlWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 370),
                styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Bopify · Lyrics study"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: LyricPanelPreviewControls(session: self))
            window.center()
            controlWindow = window
        }
        controlWindow?.makeKeyAndOrderFront(nil)
    }

    private func anchorTime() { basePosition = model.snapshot.positionMs; baseTime = now() }

    private func synchronize() {
        guard model.snapshot.isPlaying else { return }
        var input = model.snapshot
        input.positionMs = Int64(min(Double(input.durationMs), Double(basePosition) + max(0, now() - baseTime) * 1000))
        if input.positionMs >= input.durationMs { input.isPlaying = false }
        model.update(input)
    }

    private func startClock() {
        guard clock == nil, model.isVisible, model.snapshot.isPlaying else { return }
        isClockRunning = true
        let generation = clockGeneration
        let sleep = sleep
        clock = Task { [weak self] in
            while !Task.isCancelled {
                do { try await sleep(.milliseconds(100)) } catch { return }
                guard let self, !Task.isCancelled, self.clockGeneration == generation,
                      self.model.isVisible else { return }
                self.synchronize()
                if !self.model.snapshot.isPlaying { self.stopClock(); return }
            }
        }
    }

    private func stopClock() {
        clockGeneration &+= 1
        clock?.cancel()
        clock = nil
        isClockRunning = false
    }
}

private struct LyricPanelPreviewControls: View {
    let session: LyricPanelPreviewSession

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Player lyrics").font(.title2.weight(.medium))
            Text("Original sample words · simulated playback · no live audio")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Sample", selection: Binding(get: { session.fixture }, set: { session.selectFixture($0) })) {
                ForEach(LyricPreviewFixture.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            HStack {
                Button(session.model.snapshot.isPlaying ? "Pause clock" : "Play clock") {
                    session.setPlaying(!session.model.snapshot.isPlaying)
                }
                Button("Advance +5s") { session.advance(by: 5_000, explicitSeek: false) }
                Button("Seek −10s") { session.advance(by: -10_000, explicitSeek: true) }
            }
            HStack {
                Button("Correction −5s") { session.advance(by: -5_000, explicitSeek: false) }
                Button("New occurrence") { session.selectFixture(session.fixture) }
            }
            HStack {
                Button("Previous sample") { session.changeSong(.previous) }
                Button("Next sample") { session.changeSong(.next) }
            }
            HStack {
                Button("Reveal player") { session.setExpanded(true) }
                Button("Collapse to lyrics") { session.setExpanded(false) }
            }
            HStack {
                Button(session.model.isVisible ? "Hide Player" : "Show Player") {
                    if session.model.isVisible { session.hide() } else { session.show() }
                }
                Button("Focus Lyrics") { session.show(); session.model.isKeyboardInteracting = true; session.model.keyboardSelection = .reader; session.focusLyrics() }
                Spacer()
                Button("Quit Preview") { session.shutdown(); NSApp.terminate(nil) }
            }
        }.padding(24).frame(width: 440)
    }
}
#endif
