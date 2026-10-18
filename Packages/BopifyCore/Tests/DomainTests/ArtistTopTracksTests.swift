import Foundation
import Testing
import BopifyDomain

@Suite("Artist top tracks")
struct ArtistTopTracksTests {
    @Test func decodesOrderedTracksAndArtistIdentity() throws {
        let json = #"{"type":"artistTopTracks","requestID":7,"trackURI":"spotify:track:source","artistURI":"spotify:artist:artist","artistName":"Singer","tracks":[{"trackUri":"spotify:track:song","title":"Song","artists":["Singer"],"albumTitle":null,"artworkUrl":null,"durationMs":1000}]}"#
        let reply = try JSONDecoder().decode(ArtistTopTracksReply.self, from: Data(json.utf8))
        guard case let .tracks(id, result) = reply else { Issue.record("Expected songs"); return }
        #expect(id == 7)
        #expect(result.trackURI.rawValue == "spotify:track:source")
        #expect(result.artistURI.rawValue == "spotify:artist:artist")
        #expect(result.artistName == "Singer")
        #expect(result.tracks.map(\.title) == ["Song"])
    }

    @Test func rejectsWrongURIKinds() {
        let json = #"{"type":"artistTopTracks","requestID":7,"trackURI":"spotify:track:source","artistURI":"spotify:playlist:wrong","artistName":"Singer","tracks":[]}"#
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ArtistTopTracksReply.self, from: Data(json.utf8))
        }
    }

    @Test func unknownFailureRemainsRecoverable() throws {
        let json = #"{"type":"artistTopTracksFailed","requestID":8,"trackURI":"spotify:track:source","reason":"newReason"}"#
        #expect(try JSONDecoder().decode(ArtistTopTracksReply.self, from: Data(json.utf8)) ==
                .failed(requestID: 8, trackURI: SpotifyURI("spotify:track:source")!, .unavailable))
    }
}
