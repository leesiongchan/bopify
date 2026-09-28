public struct SavedTracksPage: Equatable, Sendable {
    public let tracks: [Track]
    public let nextOffset: Int?
    public let total: Int

    public init(tracks: [Track], nextOffset: Int?, total: Int) {
        self.tracks = tracks
        self.nextOffset = nextOffset
        self.total = total
    }
}

public protocol SavedTracksService: Sendable {
    func savedTracks(offset: Int, limit: Int) async throws -> SavedTracksPage
}
