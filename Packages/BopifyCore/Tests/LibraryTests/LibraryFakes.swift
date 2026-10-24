import Foundation
import BopifyDomain

func testTrack(_ id: String) -> Track {
    Track(uri: SpotifyURI("spotify:track:\(id)")!, title: "Song \(id)", artists: [], albumTitle: nil, artwork: nil, durationMs: 100_000)
}

@MainActor
func startLibraryReveal(_ reveal: @escaping @MainActor () async -> Void) async -> Task<Void, Never> {
    let (started, signal) = AsyncStream.makeStream(of: Void.self)
    let task = Task {
        signal.yield(())
        await reveal()
    }
    for await _ in started { break }
    return task
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
    private var holdsRecent = false
    private var heldRecent: CheckedContinuation<Void, Never>?

    func setPlays(_ result: Result<[RecentPlay], LibraryError>) { plays = result }
    func setTop(_ kind: TopItemKind, _ seeds: [StationSeed]) { top[kind] = seeds }
    func holdNextRecent() { holdsRecent = true }
    func waitUntilRecentHeld() async { while heldRecent == nil { await Task.yield() } }
    func releaseRecent() { heldRecent?.resume(); heldRecent = nil }

    func recentlyPlayed() async throws -> [RecentPlay] {
        recentCalls += 1
        let result = plays
        if holdsRecent {
            holdsRecent = false
            await withCheckedContinuation { heldRecent = $0 }
        }
        return try result.get()
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
