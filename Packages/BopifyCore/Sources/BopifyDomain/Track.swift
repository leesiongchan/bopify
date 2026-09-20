import Foundation

public struct ArtistSummary: Hashable, Sendable {
    public let name: String
    public init(name: String) { self.name = name }
}

public struct Artwork: Hashable, Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }
}

public struct Track: Hashable, Sendable {
    public let uri: SpotifyURI
    public let title: String
    public let artists: [ArtistSummary]
    public let albumTitle: String?
    public let artwork: Artwork?
    public let durationMs: Int64

    public init(uri: SpotifyURI, title: String, artists: [ArtistSummary],
                albumTitle: String?, artwork: Artwork?, durationMs: Int64) {
        self.uri = uri; self.title = title; self.artists = artists
        self.albumTitle = albumTitle; self.artwork = artwork; self.durationMs = durationMs
    }
}
