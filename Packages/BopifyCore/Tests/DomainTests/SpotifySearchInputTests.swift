import Foundation
import Testing
import BopifyDomain

@Suite("Spotify search input")
struct SpotifySearchInputTests {
    @Test(arguments: ["track", "album", "artist", "playlist"])
    func acceptsMusicURLsAndURIs(_ kind: String) {
        let uri = SpotifyURI("spotify:\(kind):6rqhFgbbKwnb9MLmUQDhG6")!
        for input in [uri.rawValue, "https://open.spotify.com/\(kind)/\(uri.id)",
                      " HTTP://OPEN.SPOTIFY.COM/intl-my/\(kind)/\(uri.id)/?si=sharing#fragment \n"] {
            #expect(SpotifySearchInput(input) == .resource(uri))
        }
    }

    @Test(arguments: ["", "  Björk  ", "artist:Mira year:2026", "Love: Songs", "Spotify", "spotify playlist",
                      #"track:"https://example.com""#, #"album:"https://" artist:Example"#,
                      "a song about https://example.com"])
    func leavesTextAsTrimmedSearch(_ input: String) {
        #expect(SpotifySearchInput(input) == .text(input.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    @Test(arguments: [
        "https://open.spotify.com/track/", "spotify:track:", "spotify:track:bad,id",
        "spotify:track:é", "spotify:track:abc:def", "https://open.spotify.com/track/a%2Fb",
        "https://open.spotify.com/track/a%252Fb", "https://open.spotify.com/track/abc/extra",
        "https://open.spotify.com/track/abc//", "https://open.spotify.com//track/abc",
        "https://user@open.spotify.com/track/abc", "https://open.spotify.com:443/track/abc",
        "https://open.spotify.com.evil.test/track/abc", "https://open.spotify.com@evil.test/track/abc",
        "https://example.com/track/abc", "file:///track/abc", "ftp://open.spotify.com/track/abc",
        "https://open.spotify.com/track/abc https://open.spotify.com/track/def",
        "https://open.spotify.com/track/abc\nhttps://open.spotify.com/track/def"
    ])
    func rejectsMalformedOrForeignLinks(_ input: String) {
        #expect(SpotifySearchInput(input) == .invalidLink)
    }

    @Test(arguments: [
        "spotify:episode:abc", "spotify:show:abc", "spotify:user:abc:playlist:def",
        "https://open.spotify.com/episode/abc", "https://open.spotify.com/embed/track/abc",
        "https://open.spotify.com/user/abc", "https://open.spotify.com/s/opaque",
        "https://spotify.link/opaque", "https://spoti.fi/opaque"
    ])
    func identifiesUnsupportedSpotifyLinks(_ input: String) {
        #expect(SpotifySearchInput(input) == .unsupportedLink)
    }
}
