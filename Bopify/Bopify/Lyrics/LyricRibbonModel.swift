#if DEBUG
import Observation
import BopifyDomain
import os

nonisolated struct LyricPlaybackSnapshot: Equatable, Sendable {
    var sessionID: String
    var occurrenceID: String
    var recordingID: String
    var title: String
    var artist: String
    var positionMs: Int64
    var durationMs: Int64
    var isPlaying: Bool
    var seekRevision: UInt64
}

nonisolated enum LyricContent: Equatable, Sendable {
    case loading, timed(LyricDocument), plain(String), instrumental, noMatch, failure
    case idle(LyricIdleReason)
}

nonisolated enum LyricRibbonControl: Hashable { case reading, hide }

nonisolated struct LyricLoadToken: Equatable, Sendable {
    let generation: UInt64
    let sessionID: String
    let occurrenceID: String
}

@MainActor @Observable
final class LyricRibbonModel {
    private(set) var snapshot: LyricPlaybackSnapshot
    private(set) var content: LyricContent = .loading
    private(set) var source: LyricSourceMetadata?
    private(set) var projection: LyricProjection?
    private(set) var isVisible = false
    var isKeyboardInteracting = false
    var keyboardSelection: LyricRibbonControl?
    private(set) var scrollResetRevision: UInt64 = 0
    private var heldProjection: LyricProjection?
    private var generation: UInt64 = 0
    var isHeld: Bool { heldProjection != nil }

    init(snapshot: LyricPlaybackSnapshot) { self.snapshot = snapshot }

    func update(_ next: LyricPlaybackSnapshot) {
        let changed = next.sessionID != snapshot.sessionID || next.occurrenceID != snapshot.occurrenceID
            || next.recordingID != snapshot.recordingID
        let seeked = next.seekRevision != snapshot.seekRevision
        if changed {
            generation &+= 1
            heldProjection = nil
            content = .loading
            source = nil
            BopifyLog.playback.debug("lyric input replaced generation=\(self.generation, privacy: .public)")
        } else if seeked {
            heldProjection = nil
        }
        snapshot = next
        if isVisible { reproject(resetScroll: changed || seeked) }
    }

    func show() {
        guard !isVisible else { return }
        isVisible = true
        reproject(resetScroll: true)
        BopifyLog.playback.debug("lyric ribbon shown")
    }

    func hide() {
        generation &+= 1
        heldProjection = nil
        projection = nil
        isVisible = false
        isKeyboardInteracting = false
        keyboardSelection = nil
        BopifyLog.playback.debug("lyric ribbon hidden")
    }

    func holdText() {
        guard isVisible, projection?.interval == .cue else { return }
        heldProjection = projection
        BopifyLog.playback.debug("lyric reading held")
    }

    func backToLive() {
        heldProjection = nil
        reproject(resetScroll: true)
        BopifyLog.playback.debug("lyric reading returned to live")
    }

    func beginLoad() -> LyricLoadToken {
        generation &+= 1
        heldProjection = nil
        content = .loading
        source = nil
        reproject(resetScroll: true)
        return LyricLoadToken(generation: generation, sessionID: snapshot.sessionID, occurrenceID: snapshot.occurrenceID)
    }

    func completeLoad(_ content: LyricContent, token: LyricLoadToken, source: LyricSourceMetadata? = nil) {
        guard token.generation == generation, token.sessionID == snapshot.sessionID,
              token.occurrenceID == snapshot.occurrenceID else { return }
        generation &+= 1
        self.content = content
        self.source = source
        heldProjection = nil
        reproject(resetScroll: true)
    }

    func setIdle(_ reason: LyricIdleReason) {
        generation &+= 1
        heldProjection = nil
        source = nil
        content = .idle(reason)
        reproject(resetScroll: true)
    }

    private func reproject(resetScroll: Bool) {
        let next: LyricProjection?
        if !isVisible { next = nil }
        else if let heldProjection { next = heldProjection }
        else if case let .timed(document) = content {
            next = document.project(positionMs: snapshot.positionMs, durationMs: snapshot.durationMs)
        } else { next = nil }
        if resetScroll || next != projection { scrollResetRevision &+= 1 }
        if next != projection { projection = next }
    }
}
#endif
