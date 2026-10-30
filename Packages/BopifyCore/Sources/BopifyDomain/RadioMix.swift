import Foundation

public struct RadioMix: Hashable, Sendable {
    public let contextURI: SpotifyURI
    public let tracks: [Track]

    public init(contextURI: SpotifyURI, tracks: [Track]) {
        self.contextURI = contextURI
        self.tracks = tracks
    }
}

/// Why a station could not be built; raw values are the Rust wire reasons.
public enum RadioFailure: String, Error, Hashable, Sendable {
    case noTopTrack, noMix, unavailable, network
}

/// The engine's answer to one radio request, matched to its caller by `requestID`.
public enum RadioReply: Hashable, Sendable {
    case mix(requestID: UInt64, seedURI: SpotifyURI, RadioMix)
    case failed(requestID: UInt64, seedURI: SpotifyURI, RadioFailure)

    /// Event types that carry a reply rather than playback state.
    public static let eventTypes: Set<String> = ["radio", "radioFailed"]
}

extension RadioReply: Decodable {
    private enum CodingKeys: String, CodingKey { case type, requestID, seedURI, contextURI, tracks, reason }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(UInt64.self, forKey: .requestID)
        guard let seed = SpotifyURI(try c.decode(String.self, forKey: .seedURI)) else {
            throw DecodingError.dataCorruptedError(forKey: .seedURI, in: c, debugDescription: "malformed Spotify URI")
        }
        switch try c.decode(String.self, forKey: .type) {
        case "radio":
            guard let context = SpotifyURI(try c.decode(String.self, forKey: .contextURI)) else {
                throw DecodingError.dataCorruptedError(forKey: .contextURI, in: c, debugDescription: "malformed Spotify URI")
            }
            var list = try c.nestedUnkeyedContainer(forKey: .tracks)
            var tracks: [Track] = []
            while !list.isAtEnd { tracks.append(try PlaybackEvent.decodeTrack(from: try list.superDecoder())) }
            self = .mix(requestID: id, seedURI: seed, RadioMix(contextURI: context, tracks: tracks))
        case "radioFailed":
            // A reason added on the Rust side must still fail the request rather than strand it.
            self = .failed(requestID: id, seedURI: seed, RadioFailure(rawValue: try c.decode(String.self, forKey: .reason)) ?? .unavailable)
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "not a radio reply: \(other)")
        }
    }
}
