import Foundation
import Testing
import BopifyDomain

@Suite("RadioReply")
struct RadioReplyTests {
    @Test func decodesAMixInTheRustWireShape() throws {
        let json = #"{"type":"radio","requestID":7,"seedURI":"spotify:artist:a","contextURI":"spotify:playlist:m","tracks":[{"trackUri":"spotify:track:t","title":"T","artists":["A"],"albumTitle":null,"artworkUrl":null,"durationMs":1000}]}"#
        let reply = try JSONDecoder().decode(RadioReply.self, from: Data(json.utf8))
        let track = Track(uri: SpotifyURI("spotify:track:t")!, title: "T", artists: [ArtistSummary(name: "A")],
                          albumTitle: nil, artwork: nil, durationMs: 1000)
        #expect(reply == .mix(requestID: 7, seedURI: SpotifyURI("spotify:artist:a")!,
                              RadioMix(contextURI: SpotifyURI("spotify:playlist:m")!, tracks: [track])))
    }

    @Test func decodesFailuresAndFoldsUnknownReasonsIntoUnavailable() throws {
        let known = #"{"type":"radioFailed","requestID":8,"seedURI":"spotify:track:t","reason":"noTopTrack"}"#
        #expect(try JSONDecoder().decode(RadioReply.self, from: Data(known.utf8)) == .failed(requestID: 8, seedURI: SpotifyURI("spotify:track:t")!, .noTopTrack))
        let unknown = #"{"type":"radioFailed","requestID":9,"seedURI":"spotify:track:t","reason":"somethingNew"}"#
        #expect(try JSONDecoder().decode(RadioReply.self, from: Data(unknown.utf8)) == .failed(requestID: 9, seedURI: SpotifyURI("spotify:track:t")!, .unavailable))
    }

    @Test func rejectsAMalformedSeed() {
        let json = #"{"type":"radioFailed","requestID":8,"seedURI":"not-a-uri","reason":"noMix"}"#
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(RadioReply.self, from: Data(json.utf8)) }
    }
}
