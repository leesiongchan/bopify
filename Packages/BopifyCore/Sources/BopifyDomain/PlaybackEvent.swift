import Foundation

public enum PlaybackEvent: Hashable, Sendable {
    case queueChanged(PlaybackQueue)
    case queueMetadata(generation: UInt64, entryID: String, track: Track?)
    case shuffleChanged(Bool)
    case repeatChanged(RepeatMode)
    case commandRejected(String)
    case trackChanged(Track)
    case playing(positionMs: Int64)
    case paused(positionMs: Int64)
    case seeked(positionMs: Int64)
    case positionCorrection(positionMs: Int64)
    case volumeChanged(volume: Double)
    case loading
    case endOfTrack
    case activeDeviceChanged(isActive: Bool)
    case recoveryIdentity(PlaybackIdentity)
    case connectionReady(PlaybackBootstrapOutcome)
    case sessionLost(SessionLossReason)
    case startupResolved(StartupOutcome)
    case remotePlayback(RemotePlayback?)
}

extension PlaybackEvent: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type, positionMs, volume, isActive
        case generation, entryID, track, enabled, mode, reason
        case trackUri, title, artists, albumTitle, artworkUrl, durationMs
        case outcome, deviceName, remote, isPlaying, identity
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "queueChanged": self = .queueChanged(try PlaybackQueue(from: decoder))
        case "queueMetadata":
            self = .queueMetadata(generation: try c.decode(UInt64.self, forKey: .generation),
                                  entryID: try c.decode(String.self, forKey: .entryID),
                                  track: try c.decodeNil(forKey: .track) ? nil : Self.decodeTrack(from: c.superDecoder(forKey: .track)))
        case "shuffleChanged": self = .shuffleChanged(try c.decode(Bool.self, forKey: .enabled))
        case "repeatChanged": self = .repeatChanged(try c.decode(RepeatMode.self, forKey: .mode))
        case "commandRejected": self = .commandRejected(try c.decode(String.self, forKey: .reason))
        case "playing":            self = .playing(positionMs: try c.decode(Int64.self, forKey: .positionMs))
        case "paused":             self = .paused(positionMs: try c.decode(Int64.self, forKey: .positionMs))
        case "seeked":             self = .seeked(positionMs: try c.decode(Int64.self, forKey: .positionMs))
        case "positionCorrection": self = .positionCorrection(positionMs: try c.decode(Int64.self, forKey: .positionMs))
        case "loading":            self = .loading
        case "endOfTrack":         self = .endOfTrack
        case "activeDeviceChanged": self = .activeDeviceChanged(isActive: try c.decode(Bool.self, forKey: .isActive))
        case "recoveryIdentity": self = .recoveryIdentity(try c.decode(PlaybackIdentity.self, forKey: .identity))
        case "connectionReady":
            switch try c.decode(String.self, forKey: .outcome) {
            case "local": self = .connectionReady(.local(try c.decode(PlaybackIdentity.self, forKey: .identity)))
            case "remote": self = .connectionReady(.remote)
            case "unavailable": self = .connectionReady(.unavailable)
            default: throw DecodingError.dataCorruptedError(forKey: .outcome, in: c, debugDescription: "invalid connection outcome")
            }
        case "sessionLost": self = .sessionLost(try c.decode(SessionLossReason.self, forKey: .reason))
        case "volumeChanged":
            // librespot uses a u16 volume scale; the domain uses 0...1.
            let raw = try c.decode(Double.self, forKey: .volume)
            self = .volumeChanged(volume: raw / Double(UInt16.max))
        case "trackChanged":
            self = .trackChanged(try Self.decodeTrack(from: decoder))
        case "startupResolved":
            switch try c.decode(String.self, forKey: .outcome) {
            case "restored": self = .startupResolved(.restored)
            case "likedSongs": self = .startupResolved(.likedSongs)
            case "nothing": self = .startupResolved(.nothing)
            case "remote": self = .startupResolved(.remote(deviceName: try c.decode(String.self, forKey: .deviceName)))
            case let other:
                throw DecodingError.dataCorruptedError(forKey: .outcome, in: c, debugDescription: "unrecognised startup outcome \(other)")
            }
        case "remotePlayback":
            self = .remotePlayback(try c.decodeNil(forKey: .remote) ? nil : Self.decodeRemote(from: c.superDecoder(forKey: .remote)))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unrecognised event type \(type)")
        }
    }

    static func decodeTrack(from decoder: any Decoder) throws -> Track {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decode(String.self, forKey: .trackUri)
        guard let uri = SpotifyURI(raw) else {
            throw DecodingError.dataCorruptedError(forKey: .trackUri, in: c, debugDescription: "malformed Spotify URI")
        }
        return Track(
            uri: uri,
            title: try c.decode(String.self, forKey: .title),
            artists: try c.decode([String].self, forKey: .artists).map(ArtistSummary.init(name:)),
            albumTitle: try c.decodeIfPresent(String.self, forKey: .albumTitle),
            artwork: try c.decodeIfPresent(String.self, forKey: .artworkUrl).flatMap(URL.init(string:)).map(Artwork.init(url:)),
            durationMs: try c.decode(Int64.self, forKey: .durationMs)
        )
    }

    private static func decodeRemote(from decoder: any Decoder) throws -> RemotePlayback {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decode(String.self, forKey: .trackUri)
        guard let uri = SpotifyURI(raw) else {
            throw DecodingError.dataCorruptedError(forKey: .trackUri, in: c, debugDescription: "malformed Spotify URI")
        }
        return RemotePlayback(
            deviceName: try c.decode(String.self, forKey: .deviceName),
            trackURI: uri,
            track: try c.decodeNil(forKey: .track) ? nil : Self.decodeTrack(from: c.superDecoder(forKey: .track)),
            isPlaying: try c.decode(Bool.self, forKey: .isPlaying),
            positionMs: try c.decode(Int64.self, forKey: .positionMs),
            durationMs: try c.decode(Int64.self, forKey: .durationMs)
        )
    }
}
