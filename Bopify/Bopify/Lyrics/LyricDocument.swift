#if DEBUG
import Foundation

nonisolated struct LyricCue: Equatable, Sendable {
    let id: String
    let startMs: Int64
    let text: String
}

nonisolated struct LyricCueGroup: Equatable, Sendable {
    let startMs: Int64
    var occurrenceIDs: [String]
    var text: String
}

nonisolated enum LyricInterval: Equatable, Sendable {
    case beforeFirst, cue, gap, ended
}

nonisolated struct LyricProjection: Equatable, Sendable {
    let interval: LyricInterval
    var current: LyricCueGroup?
    var previous: LyricCueGroup?
}

nonisolated enum LyricDocumentError: Error, Equatable {
    case invalidTimestamp, duplicateOccurrence
}

nonisolated struct LyricDocument: Equatable, Sendable {
    let groups: [LyricCueGroup]

    init(cues: [LyricCue]) throws {
        guard cues.allSatisfy({ $0.startMs >= 0 }) else { throw LyricDocumentError.invalidTimestamp }
        guard Set(cues.map(\.id)).count == cues.count else { throw LyricDocumentError.duplicateOccurrence }
        let ordered = cues.enumerated().sorted {
            $0.element.startMs == $1.element.startMs ? $0.offset < $1.offset : $0.element.startMs < $1.element.startMs
        }
        var result: [LyricCueGroup] = []
        for (_, cue) in ordered {
            if result.last?.startMs == cue.startMs {
                result[result.count - 1].occurrenceIDs.append(cue.id)
                result[result.count - 1].text += "\n" + cue.text
            } else {
                result.append(LyricCueGroup(startMs: cue.startMs, occurrenceIDs: [cue.id], text: cue.text))
            }
        }
        groups = result
    }

    func project(positionMs: Int64, durationMs: Int64) -> LyricProjection {
        let position = max(0, positionMs)
        if durationMs > 0, position >= durationMs { return LyricProjection(interval: .ended) }
        guard let index = groups.lastIndex(where: { $0.startMs <= position }) else {
            return LyricProjection(interval: .beforeFirst)
        }
        let previous = index > 0 ? groups[index - 1] : nil
        let group = groups[index]
        guard !group.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return LyricProjection(interval: .gap, previous: previous)
        }
        return LyricProjection(interval: .cue, current: group, previous: previous)
    }
}
#endif
