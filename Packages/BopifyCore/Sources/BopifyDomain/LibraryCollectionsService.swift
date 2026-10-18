public enum LibraryCollectionKind: String, CaseIterable, Sendable {
    case playlists, albums
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
    public let nextOffset: Int?

    public init(items: [LibraryCollection], nextOffset: Int?) {
        self.items = items
        self.nextOffset = nextOffset
    }
}

public protocol LibraryCollectionsService: Sendable {
    func savedCollections(_ kind: LibraryCollectionKind, offset: Int, limit: Int) async throws -> LibraryCollectionsPage
}
