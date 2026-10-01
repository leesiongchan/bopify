import Foundation
import BopifyDomain

func testTrack(_ id: String) -> Track {
    Track(uri: SpotifyURI("spotify:track:\(id)")!, title: "Song \(id)", artists: [], albumTitle: nil, artwork: nil, durationMs: 100_000)
}

final class TestClock: @unchecked Sendable {
    var date = Date(timeIntervalSince1970: 1000)
    func advance(_ seconds: TimeInterval) { date.addTimeInterval(seconds) }
}

actor FakeHistory: ListeningHistoryService {
    private var plays: Result<[RecentPlay], LibraryError> = .success([])
    private var top: [TopItemKind: [StationSeed]] = [:]
    private(set) var recentCalls = 0
    private(set) var topCalls = 0

    func setPlays(_ result: Result<[RecentPlay], LibraryError>) { plays = result }
    func setTop(_ kind: TopItemKind, _ seeds: [StationSeed]) { top[kind] = seeds }

    func recentlyPlayed() async throws -> [RecentPlay] {
        recentCalls += 1
        return try plays.get()
    }
    func topItems(_ kind: TopItemKind) async throws -> [StationSeed] {
        topCalls += 1
        return top[kind] ?? []
    }
}

actor FakeSavedTracks: SavedTracksService {
    private let tracks: [Track]
    private(set) var requests: [[Int]] = []
    init(_ tracks: [Track]) { self.tracks = tracks }
    func savedTracks(offset: Int, limit: Int) async throws -> SavedTracksPage {
        requests.append([offset, limit])
        return SavedTracksPage(tracks: Array(tracks.prefix(limit)), nextOffset: nil, total: tracks.count)
    }
}
