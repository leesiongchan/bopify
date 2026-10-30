import Foundation

public struct ArtistTopTracks: Hashable, Sendable {
    public let trackURI: SpotifyURI
    public let tracks: [Track]

    public init(trackURI: SpotifyURI, tracks: [Track]) {
        self.trackURI = trackURI
        self.tracks = tracks
    }
}

public enum ArtistTopTracksFailure: String, Error, Hashable, Sendable {
    case unavailable, network
}

public enum ArtistTopTracksReply: Hashable, Sendable, Decodable {
    case tracks(requestID: UInt64, ArtistTopTracks)
    case failed(requestID: UInt64, trackURI: SpotifyURI, ArtistTopTracksFailure)

    public static let eventTypes: Set<String> = ["artistTopTracks", "artistTopTracksFailed"]
    private enum CodingKeys: String, CodingKey { case type, requestID, trackURI, tracks, reason }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(UInt64.self, forKey: .requestID)
        guard let track = SpotifyURI(try c.decode(String.self, forKey: .trackURI)), track.kind == .track else {
            throw DecodingError.dataCorruptedError(forKey: .trackURI, in: c, debugDescription: "invalid source track")
        }
        switch try c.decode(String.self, forKey: .type) {
        case "artistTopTracks":
            var list = try c.nestedUnkeyedContainer(forKey: .tracks)
            guard list.count.map({ $0 <= 10 }) != false else {
                throw DecodingError.dataCorruptedError(forKey: .tracks, in: c, debugDescription: "too many artist tracks")
            }
            var tracks: [Track] = []
            while !list.isAtEnd {
                let song = try PlaybackEvent.decodeTrack(from: list.superDecoder())
                guard song.uri.kind == .track, !tracks.contains(where: { $0.uri == song.uri }) else {
                    throw DecodingError.dataCorruptedError(forKey: .tracks, in: c, debugDescription: "invalid artist track")
                }
                tracks.append(song)
            }
            self = .tracks(requestID: id, ArtistTopTracks(trackURI: track, tracks: tracks))
        case "artistTopTracksFailed":
            self = .failed(requestID: id, trackURI: track,
                ArtistTopTracksFailure(rawValue: try c.decode(String.self, forKey: .reason)) ?? .unavailable)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "invalid artist reply")
        }
    }
}
