import Foundation
import BopifyDomain

/// Balances real listening sources without inventing seeds or requiring another service.
enum ExploreDiscovery {
    static func seeds(recent: [RecentPlay], shortTermTracks: [StationSeed], shortTermArtists: [StationSeed],
                      familiarTracks: [StationSeed], liked: [Track]) -> [StationSeed] {
        let recentSeeds = recent.map { StationSeed(track: $0.track) }
        let likedSeeds = liked.map { StationSeed(track: $0) }
        var seen = Set<SpotifyURI>()
        return Array(interleave([recentSeeds, shortTermTracks, shortTermArtists, familiarTracks, likedSeeds])
            .filter { seed in
                (seed.uri.kind == .track || seed.uri.kind == .artist)
                    && !seed.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && seen.insert(seed.uri).inserted
            }.prefix(12))
    }

    static func librarySuggestions(for seed: StationSeed, sources: [[Track]], recentlyPlayed: Set<SpotifyURI>) -> [Track] {
        let candidates: [[Track]]
        if seed.isArtist {
            let artist = seed.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            candidates = sources.map { source in
                source.filter { track in
                    track.artists.contains { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == artist }
                }
            }
        } else { candidates = sources }
        return Array(rank(candidates: candidates, recentlyPlayed: recentlyPlayed, excluding: []).prefix(50))
    }

    static func rank(candidates: [[Track]], recentlyPlayed: Set<SpotifyURI>, excluding: Set<SpotifyURI>,
                     preceding: [Track] = []) -> [Track] {
        var seen = excluding
        let unique = interleave(candidates).filter { $0.uri.kind == .track && seen.insert($0.uri).inserted }
        let unheard = unique.filter { !recentlyPlayed.contains($0.uri) }
        let familiar = unique.filter { recentlyPlayed.contains($0.uri) }
        var result: [Track] = []
        for partition in [unheard, familiar] {
            var remaining = partition
            while !remaining.isEmpty {
                let window = (preceding + result).suffix(3).compactMap(artistKey)
                let index = remaining.firstIndex { candidate in
                    guard let artist = artistKey(candidate) else { return true }
                    return window.filter { $0 == artist }.count < 2
                } ?? remaining.startIndex
                result.append(remaining.remove(at: index))
            }
        }
        return result
    }

    private static func artistKey(_ track: Track) -> String? {
        guard let name = track.artists.first?.name.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        return name.lowercased()
    }

    private static func interleave<Element>(_ sources: [[Element]]) -> [Element] {
        var result: [Element] = []
        for index in 0..<(sources.map(\.count).max() ?? 0) {
            for source in sources where index < source.count { result.append(source[index]) }
        }
        return result
    }
}
