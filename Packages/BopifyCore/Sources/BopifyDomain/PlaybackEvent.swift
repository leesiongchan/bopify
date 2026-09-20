import Foundation

public enum PlaybackEvent: Hashable, Sendable {
    case trackChanged(Track)
    case playing(positionMs: Int64)
    case paused(positionMs: Int64)
    case seeked(positionMs: Int64)
    case positionCorrection(positionMs: Int64)
    case volumeChanged(volume: Double)
    case loading
    case endOfTrack
    case activeDeviceChanged(isActive: Bool)
    case failed(PlayerError)
}

extension PlaybackEvent: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type, positionMs, volume, isActive, code
        case trackUri, title, artists, albumTitle, artworkUrl, durationMs
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "playing":            self = .playing(positionMs: try c.decode(Int64.self, forKey: .positionMs))
        case "paused":             self = .paused(positionMs: try c.decode(Int64.self, forKey: .positionMs))
        case "seeked":             self = .seeked(positionMs: try c.decode(Int64.self, forKey: .positionMs))
        case "positionCorrection": self = .positionCorrection(positionMs: try c.decode(Int64.self, forKey: .positionMs))
        case "loading":            self = .loading
        case "endOfTrack":         self = .endOfTrack
        case "activeDeviceChanged": self = .activeDeviceChanged(isActive: try c.decode(Bool.self, forKey: .isActive))
        case "failed":             self = .failed(PlayerError(ffiCode: try c.decode(Int32.self, forKey: .code)))
        case "volumeChanged":
            // librespot uses a u16 volume scale; the domain uses 0...1.
            let raw = try c.decode(Double.self, forKey: .volume)
            self = .volumeChanged(volume: raw / Double(UInt16.max))
        case "trackChanged":
            let raw = try c.decode(String.self, forKey: .trackUri)
            guard let uri = SpotifyURI(raw) else {
                throw DecodingError.dataCorruptedError(forKey: .trackUri, in: c, debugDescription: "malformed Spotify URI")
            }
            self = .trackChanged(Track(
                uri: uri,
                title: try c.decode(String.self, forKey: .title),
                artists: try c.decode([String].self, forKey: .artists).map(ArtistSummary.init(name:)),
                albumTitle: try c.decodeIfPresent(String.self, forKey: .albumTitle),
                artwork: try c.decodeIfPresent(String.self, forKey: .artworkUrl).flatMap(URL.init(string:)).map(Artwork.init(url:)),
                durationMs: try c.decode(Int64.self, forKey: .durationMs)
            ))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unrecognised event type \(type)")
        }
    }
}
