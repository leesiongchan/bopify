#if DEBUG
import AppKit
import Observation
import SwiftUI

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
final class LyricRibbonPreviewSession {
    let model: LyricRibbonModel
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
    @ObservationIgnored private(set) lazy var controller = LyricRibbonWindowController(model: model, defaults: defaults,
        onHide: { [weak self] in self?.hide() })

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         defaults: UserDefaults = .standard) {
        self.now = now
        self.sleep = sleep
        self.defaults = defaults
        baseTime = now()
        model = LyricRibbonModel(snapshot: LyricPlaybackSnapshot(sessionID: UUID().uuidString,
            occurrenceID: UUID().uuidString, recordingID: "original-timed", title: "Window Seat", artist: "Soft Weather",
            positionMs: 72_000, durationMs: 100_000, isPlaying: true, seekRevision: 0))
        model.completeLoad(fixture.content, token: model.beginLoad())
    }

    func show() {
        synchronize()
        controller.show()
        startClock()
    }

    func hide() { stopClock(); controller.hide() }

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
        model.completeLoad(fixture.content, token: model.beginLoad())
        anchorTime()
        controller.refreshLayout(textScale: 1)
    }

    func shutdown() {
        hide()
        controlWindow?.close()
        controlWindow = nil
    }

    func showControls() {
        if controlWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 330),
                styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Bopify · Lyric ribbon study"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: LyricRibbonPreviewControls(session: self))
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

private struct LyricRibbonPreviewControls: View {
    let session: LyricRibbonPreviewSession
    @State private var textScale = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Quiet ribbon").font(.title2.weight(.medium))
            Text("Original sample words · simulated playback · no live audio")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Sample", selection: Binding(get: { session.fixture }, set: { session.selectFixture($0); textScale = 1 })) {
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
                Text("Text size")
                Slider(value: $textScale, in: 1...1.5).onChange(of: textScale) { _, value in
                    session.controller.refreshLayout(textScale: value)
                }
            }
            HStack {
                Button(session.model.isVisible ? "Hide Ribbon" : "Show Ribbon") {
                    if session.model.isVisible { session.hide() } else { session.show() }
                }
                Button("Focus Ribbon") { session.show(); session.controller.focusForReading() }
                Spacer()
                Button("Quit Preview") { session.shutdown(); NSApp.terminate(nil) }
            }
        }.padding(24).frame(width: 440)
    }
}
#endif
