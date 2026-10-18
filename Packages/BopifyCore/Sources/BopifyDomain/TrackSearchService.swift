public struct TrackSearchPage: Equatable, Sendable {
    public let tracks: [Track]
    public let nextOffset: Int?

    public init(tracks: [Track], nextOffset: Int?) {
        self.tracks = tracks
        self.nextOffset = nextOffset
    }
}

public protocol TrackSearchService: Sendable {
    func searchTracks(query: String, offset: Int, limit: Int) async throws -> TrackSearchPage
}
