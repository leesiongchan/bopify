public enum LibraryCollectionKind: String, CaseIterable, Sendable {
    case playlists, albums, artists
}

public enum LibraryCollectionCursor: Equatable, Sendable {
    case offset(Int)
    case after(String?)
}

public struct LibraryCollection: Equatable, Sendable {
    public let uri: SpotifyURI
    public let title: String
    public let subtitle: String
    public let artwork: Artwork?

    public init(uri: SpotifyURI, title: String, subtitle: String, artwork: Artwork?) {
        self.uri = uri; self.title = title; self.subtitle = subtitle; self.artwork = artwork
    }
}

public struct LibraryCollectionsPage: Equatable, Sendable {
    public let items: [LibraryCollection]
    public let nextCursor: LibraryCollectionCursor?

    public init(items: [LibraryCollection], nextCursor: LibraryCollectionCursor?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

public protocol LibraryCollectionsService: Sendable {
    func savedCollections(_ kind: LibraryCollectionKind, cursor: LibraryCollectionCursor, limit: Int) async throws -> LibraryCollectionsPage
}
