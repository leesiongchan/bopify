import Foundation
import BopifyDomain

nonisolated enum LyricIdleReason: Equatable, Sendable {
    case noTrack, loadingTrack, otherDevice, connecting, unsupported, playbackUnavailable

    var message: String {
        switch self {
        case .noTrack: String(localized: "idle.noTrack", defaultValue: "Play music on this Mac", table: "LyricRibbon")
        case .loadingTrack: String(localized: "idle.loadingTrack", defaultValue: "Loading track…", table: "LyricRibbon")
        case .otherDevice: String(localized: "idle.otherDevice", defaultValue: "This ribbon follows playback on this Mac", table: "LyricRibbon")
        case .connecting: String(localized: "idle.connecting", defaultValue: "Connecting to playback…", table: "LyricRibbon")
        case .unsupported: String(localized: "idle.unsupported", defaultValue: "Lyrics unavailable for this item", table: "LyricRibbon")
        case .playbackUnavailable: String(localized: "idle.playbackUnavailable", defaultValue: "Playback unavailable", table: "LyricRibbon")
        }
    }
}

nonisolated struct LyricSourceMetadata: Equatable, Sendable {
    let provider: String
    let providerDisplayName: String
    let language: String
    let isRightToLeft: Bool

    init(lyrics: TrackLyrics) {
        provider = lyrics.provider
        providerDisplayName = lyrics.providerDisplayName
        language = lyrics.language
        isRightToLeft = lyrics.isRightToLeft
    }

    var attribution: String? {
        if !providerDisplayName.isEmpty { return providerDisplayName }
        return provider.isEmpty ? nil : provider
    }
}

nonisolated struct LyricPresentation: Equatable, Sendable {
    let content: LyricContent
    let source: LyricSourceMetadata

    init(lyrics: TrackLyrics) throws {
        source = LyricSourceMetadata(lyrics: lyrics)
        switch lyrics.synchronization {
        case .lineSynced:
            let cues = try lyrics.lines.enumerated().map { index, line in
                guard let start = line.startTimeMs, start >= 0 else { throw LyricDocumentError.invalidTimestamp }
                return LyricCue(id: String(index), startMs: start, text: line.text)
            }
            content = .timed(try LyricDocument(cues: cues))
        case .unsynced:
            content = .plain(lyrics.lines.map(\.text).joined(separator: "\n"))
        }
    }
}
