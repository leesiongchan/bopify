import Foundation

public enum RepeatMode: String, Codable, Hashable, Sendable { case off, context, track }

public struct QueueTarget: Hashable, Sendable {
    public let engineEpoch: UInt64
    public let generation: UInt64
    public let rawNextIndex: UInt32
    public init(generation: UInt64, rawNextIndex: UInt32, engineEpoch: UInt64 = 0) {
        self.engineEpoch = engineEpoch
        self.generation = generation
        self.rawNextIndex = rawNextIndex
    }
}

public struct QueueEntry: Hashable, Sendable, Identifiable {
    public let id: String
    public let uri: SpotifyURI?
    public let target: QueueTarget?
    public var track: Track?
    public var metadataFailed: Bool

    public init(id: String, uri: SpotifyURI?, target: QueueTarget?, track: Track?, metadataFailed: Bool) {
        self.id = id
        self.uri = uri
        self.target = target
        self.track = track
        self.metadataFailed = metadataFailed
    }
}

public struct PlaybackQueue: Hashable, Sendable {
    public let generation: UInt64
    public var previous: [QueueEntry]
    public var current: QueueEntry?
    public var next: [QueueEntry]

    public init(generation: UInt64, previous: [QueueEntry], current: QueueEntry?, next: [QueueEntry]) {
        self.generation = generation
        self.previous = previous
        self.current = current
        self.next = next
    }
}

extension PlaybackQueue: Decodable {
    private struct WireEntry: Decodable {
        let id: String
        let uri: String?
        let rawNextIndex: UInt32?

        func entry(generation: UInt64, selectable: Bool) -> QueueEntry {
            let parsed = uri.flatMap(SpotifyURI.init)
            let playable = parsed?.kind == .track || parsed?.kind == .episode
            return QueueEntry(id: id, uri: playable ? parsed : nil,
                target: selectable && playable ? rawNextIndex.map { QueueTarget(generation: generation, rawNextIndex: $0) } : nil,
                track: nil, metadataFailed: !playable)
        }
    }
    private enum CodingKeys: CodingKey { case generation, previous, current, next }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let generation = try c.decode(UInt64.self, forKey: .generation)
        let previous = try c.decode([WireEntry].self, forKey: .previous)
        let current = try c.decodeIfPresent(WireEntry.self, forKey: .current)
        let next = try c.decode([WireEntry].self, forKey: .next)
        let ids = (previous + (current.map { [$0] } ?? []) + next).map(\.id)
        let targets = next.compactMap(\.rawNextIndex)
        guard ids.allSatisfy({ !$0.isEmpty }), Set(ids).count == ids.count,
              Set(targets).count == targets.count else {
            throw DecodingError.dataCorruptedError(forKey: .next, in: c, debugDescription: "duplicate or empty queue identity")
        }
        self.init(generation: generation,
                  previous: previous.map { $0.entry(generation: generation, selectable: false) },
                  current: current?.entry(generation: generation, selectable: false),
                  next: next.map { $0.entry(generation: generation, selectable: true) })
    }
}
