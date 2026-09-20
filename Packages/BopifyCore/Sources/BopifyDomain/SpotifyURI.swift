/// A validated Spotify URI. Parsing at the boundary means no other type
/// has to defend against malformed identifiers.
public struct SpotifyURI: Hashable, Sendable, CustomStringConvertible {
    public enum Kind: Hashable, Sendable {
        case track, album, artist, playlist, episode, show
        case other(String)

        init(_ raw: String) {
            switch raw {
            case "track": self = .track
            case "album": self = .album
            case "artist": self = .artist
            case "playlist": self = .playlist
            case "episode": self = .episode
            case "show": self = .show
            default: self = .other(raw)
            }
        }
    }

    public let rawValue: String
    public let kind: Kind
    public let id: String

    public init?(_ raw: String) {
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == "spotify",
              !parts[1].isEmpty, !parts[2].isEmpty else { return nil }
        self.rawValue = raw
        self.kind = Kind(parts[1])
        self.id = parts[2]
    }

    public var description: String { rawValue }
}
