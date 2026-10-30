import Observation
import Foundation
import BopifyDomain
import BopifyPlayback
import os

nonisolated struct LyricPlaybackSnapshot: Equatable, Sendable {
    var sessionID: String
    var occurrenceID: String
    var recordingID: String
    var positionMs: Int64
    var durationMs: Int64
    var isPlaying: Bool
    var seekRevision: UInt64
    var direction: CarouselDirection = .fade
}

nonisolated enum LyricContent: Equatable, Sendable {
    case loading, timed(LyricDocument), plain(String), instrumental, noMatch, failure
    case idle(LyricIdleReason)
}

nonisolated enum LyricRibbonControl: Hashable { case reader, sync }

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
    private(set) var isReading = false
    private var generation: UInt64 = 0

    init(snapshot: LyricPlaybackSnapshot) { self.snapshot = snapshot }

    func update(_ next: LyricPlaybackSnapshot) {
        let changed = next.sessionID != snapshot.sessionID || next.occurrenceID != snapshot.occurrenceID
            || next.recordingID != snapshot.recordingID
        let seeked = next.seekRevision != snapshot.seekRevision
        if changed {
            generation &+= 1
            resumeFollowing()
            content = .loading
            source = nil
            BopifyLog.playback.debug("lyric input replaced generation=\(self.generation, privacy: .public)")
        } else if seeked {
            resumeFollowing()
        }
        snapshot = next
        if isVisible { reproject(resetScroll: changed || seeked) }
    }

    func show() {
        guard !isVisible else { return }
        isVisible = true
        reproject(resetScroll: true)
        BopifyLog.playback.debug("lyric panel shown")
    }

    func hide() {
        generation &+= 1
        resumeFollowing()
        projection = nil
        isVisible = false
        isKeyboardInteracting = false
        keyboardSelection = nil
        BopifyLog.playback.debug("lyric panel hidden")
    }

    func beginReading() {
        guard isVisible, !isReading, case .timed = content else { return }
        isReading = true
        BopifyLog.playback.debug("lyric manual reading started")
    }

    func backToLive() {
        resumeFollowing()
        reproject(resetScroll: true)
        BopifyLog.playback.debug("lyric reading returned to live")
    }

    func beginLoad() -> LyricLoadToken {
        generation &+= 1
        resumeFollowing()
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
        resumeFollowing()
        reproject(resetScroll: true)
    }

    func setIdle(_ reason: LyricIdleReason) {
        generation &+= 1
        resumeFollowing()
        source = nil
        content = .idle(reason)
        reproject(resetScroll: true)
    }

    private func resumeFollowing() {
        isReading = false
        if keyboardSelection == .sync { keyboardSelection = .reader }
    }

    private func reproject(resetScroll: Bool) {
        let next: LyricProjection?
        if !isVisible { next = nil }
        else if case let .timed(document) = content {
            next = document.project(positionMs: snapshot.positionMs, durationMs: snapshot.durationMs)
        } else { next = nil }
        if resetScroll || (!isReading && next != projection) { scrollResetRevision &+= 1 }
        if next != projection { projection = next }
    }
}
