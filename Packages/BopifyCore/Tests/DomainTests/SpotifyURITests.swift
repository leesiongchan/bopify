import Testing
@testable import BopifyDomain

@Suite("SpotifyURI")
struct SpotifyURITests {
    @Test func parsesATrackURI() throws {
        let uri = try #require(SpotifyURI("spotify:track:6rqhFgbbKwnb9MLmUQDhG6"))
        #expect(uri.kind == .track)
        #expect(uri.id == "6rqhFgbbKwnb9MLmUQDhG6")
        #expect(uri.rawValue == "spotify:track:6rqhFgbbKwnb9MLmUQDhG6")
    }

    @Test(arguments: ["", "spotify:track", "spotify::abc", "http://open.spotify.com/track/abc", "spotify:track:"])
    func rejectsMalformedInput(_ raw: String) {
        #expect(SpotifyURI(raw) == nil)
    }

    @Test func treatsUnknownKindsAsUnsupportedRatherThanCrashing() throws {
        let uri = try #require(SpotifyURI("spotify:audiobook:abc123"))
        #expect(uri.kind == .other("audiobook"))
    }
}
