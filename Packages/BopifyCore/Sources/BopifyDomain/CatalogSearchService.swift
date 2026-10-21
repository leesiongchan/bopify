public enum CatalogSearchKind: String, CaseIterable, Hashable, Sendable {
    case song = "track", album, artist, playlist
}

public enum CatalogSearchResult: Equatable, Sendable {
    case song(Track), album(LibraryCollection), artist(LibraryCollection), playlist(LibraryCollection)

    public var kind: CatalogSearchKind {
        switch self {
        case .song: .song
        case .album: .album
        case .artist: .artist
        case .playlist: .playlist
        }
    }
    public var uri: SpotifyURI {
        switch self {
        case let .song(track): track.uri
        case let .album(item), let .artist(item), let .playlist(item): item.uri
        }
    }
    public var title: String {
        switch self {
        case let .song(track): track.title
        case let .album(item), let .artist(item), let .playlist(item): item.title
        }
    }
    public var subtitle: String {
        switch self {
        case let .song(track): track.artists.map(\.name).joined(separator: ", ")
        case let .album(item), let .artist(item), let .playlist(item): item.subtitle
        }
    }
    public var artwork: Artwork? {
        switch self {
        case let .song(track): track.artwork
        case let .album(item), let .artist(item), let .playlist(item): item.artwork
        }
    }
}

public struct CatalogSearchPage: Equatable, Sendable {
    public let results: [CatalogSearchResult]
    public let nextOffset: Int?

    public init(results: [CatalogSearchResult], nextOffset: Int?) {
        self.results = results; self.nextOffset = nextOffset
    }
}

public protocol CatalogSearchService: Sendable {
    func search(query: String, kinds: Set<CatalogSearchKind>, offset: Int, limit: Int)
        async throws -> [CatalogSearchKind: CatalogSearchPage]
}
