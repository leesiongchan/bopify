import Foundation

public enum LyricSynchronization: String, Codable, Hashable, Sendable {
    case lineSynced, unsynced
}

public struct TrackLyricLine: Hashable, Sendable {
    public let text: String
    public let startTimeMs: Int64?

    public init(text: String, startTimeMs: Int64?) {
        self.text = text
        self.startTimeMs = startTimeMs
    }
}

public struct TrackLyrics: Hashable, Sendable {
    public let trackURI: SpotifyURI
    public let synchronization: LyricSynchronization
    public let lines: [TrackLyricLine]
    public let provider: String
    public let providerDisplayName: String
    public let language: String
    public let isRightToLeft: Bool

    public init(trackURI: SpotifyURI, synchronization: LyricSynchronization, lines: [TrackLyricLine],
                provider: String, providerDisplayName: String, language: String, isRightToLeft: Bool) {
        self.trackURI = trackURI
        self.synchronization = synchronization
        self.lines = lines
        self.provider = provider
        self.providerDisplayName = providerDisplayName
        self.language = language
        self.isRightToLeft = isRightToLeft
    }
}

public enum LyricFailure: String, Error, Hashable, Sendable {
    case noLyrics, network, unavailable
}

public enum LyricReply: Hashable, Sendable {
    case lyrics(requestID: UInt64, TrackLyrics)
    case failed(requestID: UInt64, trackURI: SpotifyURI, LyricFailure)

    public static let eventTypes: Set<String> = ["lyrics", "lyricsFailed"]

    public var requestID: UInt64 {
        switch self {
        case let .lyrics(id, _): id
        case let .failed(id, _, _): id
        }
    }

    public var trackURI: SpotifyURI {
        switch self {
        case let .lyrics(_, lyrics): lyrics.trackURI
        case let .failed(_, track, _): track
        }
    }
}

extension LyricReply: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type, requestID, trackURI, synchronization, lines, text, startTimeMs
        case provider, providerDisplayName, language, isRightToLeft, reason
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(UInt64.self, forKey: .requestID)
        guard let track = SpotifyURI(try c.decode(String.self, forKey: .trackURI)), track.kind == .track else {
            throw DecodingError.dataCorruptedError(forKey: .trackURI, in: c, debugDescription: "expected a Spotify track URI")
        }
        switch try c.decode(String.self, forKey: .type) {
        case "lyrics":
            let synchronization = try c.decode(LyricSynchronization.self, forKey: .synchronization)
            var list = try c.nestedUnkeyedContainer(forKey: .lines)
            var lines: [TrackLyricLine] = []
            while !list.isAtEnd {
                let line = try list.nestedContainer(keyedBy: CodingKeys.self)
                let text = try line.decode(String.self, forKey: .text)
                let start: Int64?
                switch synchronization {
                case .lineSynced:
                    let value = try line.decode(Int64.self, forKey: .startTimeMs)
                    guard value >= 0 else {
                        throw DecodingError.dataCorruptedError(forKey: .startTimeMs, in: line, debugDescription: "negative lyric start")
                    }
                    start = value
                case .unsynced:
                    guard try line.decodeNil(forKey: .startTimeMs) else {
                        throw DecodingError.dataCorruptedError(forKey: .startTimeMs, in: line, debugDescription: "unsynced lyric has a start")
                    }
                    start = nil
                }
                lines.append(TrackLyricLine(text: text, startTimeMs: start))
            }
            self = .lyrics(requestID: id, TrackLyrics(
                trackURI: track, synchronization: synchronization, lines: lines,
                provider: try c.decode(String.self, forKey: .provider),
                providerDisplayName: try c.decode(String.self, forKey: .providerDisplayName),
                language: try c.decode(String.self, forKey: .language),
                isRightToLeft: try c.decode(Bool.self, forKey: .isRightToLeft)))
        case "lyricsFailed":
            self = .failed(requestID: id, trackURI: track,
                           LyricFailure(rawValue: try c.decode(String.self, forKey: .reason)) ?? .unavailable)
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "not a lyric reply: \(other)")
        }
    }
}
