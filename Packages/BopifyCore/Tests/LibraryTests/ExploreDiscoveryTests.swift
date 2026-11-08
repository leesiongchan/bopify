import Testing
import BopifyDomain
@testable import BopifyLibrary

@Suite("Explore discovery ranking")
struct ExploreDiscoveryTests {
    private func track(_ id: String, artist: String = "") -> Track {
        Track(uri: SpotifyURI("spotify:track:\(id)")!, title: id,
              artists: artist.isEmpty ? [] : [ArtistSummary(name: artist)],
              albumTitle: nil, artwork: nil, durationMs: 180_000)
    }

    private func seed(_ id: String, artist: Bool = false) -> StationSeed {
        StationSeed(uri: SpotifyURI("spotify:\(artist ? "artist" : "track"):\(id)")!, name: id)
    }

    @Test func seedsBlendRecentTasteFavoritesAndFamiliarListening() {
        let recent = [RecentPlay(track: track("recent"), contextURI: nil)]
        let result = ExploreDiscovery.seeds(recent: recent, shortTermTracks: [seed("current")],
            shortTermArtists: [seed("artist", artist: true)], familiarTracks: [seed("familiar")], liked: [track("liked")])
        #expect(result.map(\.name) == ["recent", "current", "artist", "familiar", "liked"])
    }

    @Test func seedsDeduplicateAcrossSourcesAndUseOnlyRealMusicInputs() {
        let invalid = StationSeed(uri: SpotifyURI("spotify:playlist:fixture")!, name: "Playlist")
        let result = ExploreDiscovery.seeds(recent: [RecentPlay(track: track("same"), contextURI: nil)],
            shortTermTracks: [seed("same"), invalid], shortTermArtists: [seed("artist", artist: true)],
            familiarTracks: [seed("same")], liked: [track("liked")])
        #expect(result.map(\.uri) == [track("same").uri, seed("artist", artist: true).uri, track("liked").uri])
        #expect(ExploreDiscovery.seeds(recent: [], shortTermTracks: [], shortTermArtists: [], familiarTracks: [], liked: []).isEmpty)
    }

    @Test func seedBudgetIsSharedRatherThanConsumedByOneSource() {
        let result = ExploreDiscovery.seeds(recent: (0..<20).map { RecentPlay(track: track("recent\($0)"), contextURI: nil) },
            shortTermTracks: [seed("current")], shortTermArtists: [seed("artist", artist: true)],
            familiarTracks: [seed("familiar")], liked: [track("liked")])
        #expect(result.count == 12)
        #expect(Set(result.prefix(5).map(\.name)) == ["recent0", "current", "artist", "familiar", "liked"])
    }

    @Test func rankingBlendsStationsAndFiltersDuplicatesAndExcludedSongs() {
        let a = track("a"), b = track("b"), c = track("c"), d = track("d"), excluded = track("excluded")
        let result = ExploreDiscovery.rank(candidates: [[a, b, excluded], [c, a, d]],
                                            recentlyPlayed: [], excluding: [excluded.uri])
        #expect(result.map(\.uri) == [a.uri, c.uri, b.uri, d.uri])
    }

    @Test func recentSongsRemainAvailableAfterUnheardCandidates() {
        let recent = track("recent"), first = track("first"), second = track("second")
        let result = ExploreDiscovery.rank(candidates: [[recent, first], [second]],
                                            recentlyPlayed: [recent.uri], excluding: [])
        #expect(result.map(\.uri) == [second.uri, first.uri, recent.uri])
    }

    @Test func rankingSpacesTheSamePrimaryArtistWhenAlternativesExist() {
        let candidates = [track("a1", artist: "Artist A"), track("a2", artist: " artist a "),
                          track("a3", artist: "Artist A"), track("b1", artist: "Artist B"),
                          track("b2", artist: "Artist B"), track("c1", artist: "Artist C")]
        let result = ExploreDiscovery.rank(candidates: [candidates], recentlyPlayed: [], excluding: [])
        #expect(result.map(\.uri) == [candidates[0], candidates[1], candidates[3], candidates[4], candidates[2], candidates[5]].map(\.uri))
    }

    @Test func sparseArtistCatalogsAndMissingArtistMetadataDoNotLoseSongs() {
        for artist in ["Only Artist", ""] {
            let songs = (0..<8).map { track("song\($0)", artist: artist) }
            let result = ExploreDiscovery.rank(candidates: [songs], recentlyPlayed: [], excluding: [])
            #expect(result == songs)
        }
    }

    @Test func appendedCandidatesRespectArtistsAtTheExistingFeedBoundary() {
        let preceding = [track("old1", artist: "Artist A"), track("old2", artist: "Artist A")]
        let sameArtist = track("same", artist: "Artist A"), otherArtist = track("other", artist: "Artist B")
        let result = ExploreDiscovery.rank(candidates: [[sameArtist, otherArtist]], recentlyPlayed: [],
                                            excluding: [], preceding: preceding)
        #expect(result.map(\.uri) == [otherArtist.uri, sameArtist.uri])
    }
}
