public struct SavedTracksPage: Equatable, Sendable {
    public let tracks: [Track]
    public let nextOffset: Int?

    public init(tracks: [Track], nextOffset: Int?) {
        self.tracks = tracks
        self.nextOffset = nextOffset
    }
}

public protocol SavedTracksService: Sendable {
    func savedTracks(offset: Int, limit: Int) async throws -> SavedTracksPage
}
