public struct RecentPlay: Hashable, Sendable {
    public let track: Track
    /// What the track was played from, when Spotify says and the URI is one Bopify can load.
    public let contextURI: SpotifyURI?

    public init(track: Track, contextURI: SpotifyURI?) {
        self.track = track
        self.contextURI = contextURI
    }
}

/// A track or artist from the listener's history or saved music.
public struct StationSeed: Hashable, Sendable, Identifiable {
    public let uri: SpotifyURI
    public let name: String
    /// Present when a source already returned playable track metadata.
    public let track: Track?
    public var id: SpotifyURI { uri }
    public var isArtist: Bool { uri.kind == .artist }

    public init(uri: SpotifyURI, name: String) {
        self.uri = uri
        self.name = name
        self.track = nil
    }

    public init(track: Track) {
        uri = track.uri
        name = track.title
        self.track = track
    }
}

public enum TopItemKind: String, Sendable {
    case tracks, artists
}

public enum TopItemTimeRange: String, Sendable {
    case shortTerm = "short_term"
    case mediumTerm = "medium_term"
    case longTerm = "long_term"
}

public protocol ListeningHistoryService: Sendable {
    func recentlyPlayed() async throws -> [RecentPlay]
    func topItems(_ kind: TopItemKind) async throws -> [StationSeed]
    func topItems(_ kind: TopItemKind, timeRange: TopItemTimeRange) async throws -> [StationSeed]
}

extension ListeningHistoryService {
    /// Providers without range support retain their existing history behavior.
    public func topItems(_ kind: TopItemKind, timeRange: TopItemTimeRange) async throws -> [StationSeed] {
        try await topItems(kind)
    }
}
