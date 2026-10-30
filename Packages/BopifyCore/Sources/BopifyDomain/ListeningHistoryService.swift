public struct RecentPlay: Hashable, Sendable {
    public let track: Track
    /// What the track was played from, when Spotify says and the URI is one Bopify can load.
    public let contextURI: SpotifyURI?

    public init(track: Track, contextURI: SpotifyURI?) {
        self.track = track
        self.contextURI = contextURI
    }
}

/// A station seed: a top track, a top artist, or a liked song when Spotify has no top items.
public struct StationSeed: Hashable, Sendable, Identifiable {
    public let uri: SpotifyURI
    public let name: String
    public var id: SpotifyURI { uri }
    public var isArtist: Bool { uri.kind == .artist }

    public init(uri: SpotifyURI, name: String) {
        self.uri = uri
        self.name = name
    }
}

public enum TopItemKind: String, Sendable {
    case tracks, artists
}

public protocol ListeningHistoryService: Sendable {
    func recentlyPlayed() async throws -> [RecentPlay]
    func topItems(_ kind: TopItemKind) async throws -> [StationSeed]
}
