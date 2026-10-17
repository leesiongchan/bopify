import Foundation
import Testing
import BopifyDomain

@Suite("LyricReply")
struct LyricReplyTests {
    private let track = SpotifyURI("spotify:track:11dFghVXANMlKmJXsNCbNl")!

    @Test func timedReplyPreservesOrderAndAttribution() throws {
        let reply = try decode(lyricJSON())
        guard case let .lyrics(id, lyrics) = reply else {
            Issue.record("expected lyrics")
            return
        }
        #expect(id == 42)
        #expect(reply.requestID == 42)
        #expect(reply.trackURI == track)
        #expect(lyrics.trackURI == track)
        #expect(lyrics.synchronization == .lineSynced)
        #expect(lyrics.lines.map(\.startTimeMs) == [1000, 1000, 2000])
        #expect(lyrics.lines.map(\.text) == ["A quiet street", "", "The lamps return"])
        #expect(lyrics.provider == "fixture")
        #expect(lyrics.providerDisplayName == "Fixture provider")
        #expect(lyrics.language == "ar")
        #expect(lyrics.isRightToLeft)
        #expect(LyricReply.eventTypes == ["lyrics", "lyricsFailed"])
    }

    @Test func unsyncedReplyHasNoStarts() throws {
        var json = lyricJSON()
        json["synchronization"] = "unsynced"
        json["lines"] = [["text": "A quiet street", "startTimeMs": NSNull()],
                         ["text": "", "startTimeMs": NSNull()]]
        guard case let .lyrics(_, lyrics) = try decode(json) else {
            Issue.record("expected lyrics")
            return
        }
        #expect(lyrics.synchronization == .unsynced)
        #expect(lyrics.lines.count == 2)
        #expect(lyrics.lines.allSatisfy { $0.startTimeMs == nil })
    }

    @Test(arguments: ["noLyrics", "network", "unavailable", "newReason"])
    func unknownFailureBecomesUnavailable(reason: String) throws {
        let reply = try decode(["type": "lyricsFailed", "requestID": 42,
                                "trackURI": track.rawValue, "reason": reason])
        #expect(reply == .failed(requestID: 42, trackURI: track,
                                 LyricFailure(rawValue: reason) ?? .unavailable))
    }

    @Test(arguments: ["nonTrack", "unknownSync", "missingProvider", "missingDisplayName",
                      "missingLanguage", "missingRTL", "negativeStart", "missingStart",
                      "nullTimedStart", "unsyncedStart", "wrongRequestID", "wrongText"])
    func rejectsMalformedReplies(defect: String) throws {
        var json = lyricJSON()
        switch defect {
        case "nonTrack": json["trackURI"] = "spotify:album:11dFghVXANMlKmJXsNCbNl"
        case "unknownSync": json["synchronization"] = "wordSynced"
        case "missingProvider": json.removeValue(forKey: "provider")
        case "missingDisplayName": json.removeValue(forKey: "providerDisplayName")
        case "missingLanguage": json.removeValue(forKey: "language")
        case "missingRTL": json.removeValue(forKey: "isRightToLeft")
        case "negativeStart": json["lines"] = [["text": "A quiet street", "startTimeMs": -1]]
        case "missingStart": json["lines"] = [["text": "A quiet street"]]
        case "nullTimedStart": json["lines"] = [["text": "A quiet street", "startTimeMs": NSNull()]]
        case "unsyncedStart": json["synchronization"] = "unsynced"
        case "wrongRequestID": json["requestID"] = "42"
        case "wrongText": json["lines"] = [["text": 3, "startTimeMs": 1000]]
        default: preconditionFailure("unknown fixture defect")
        }
        #expect(throws: DecodingError.self) { try decode(json) }
    }

    private func decode(_ json: [String: Any]) throws -> LyricReply {
        try JSONDecoder().decode(LyricReply.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func lyricJSON() -> [String: Any] {
        ["type": "lyrics", "requestID": 42, "trackURI": track.rawValue,
         "synchronization": "lineSynced",
         "lines": [["text": "A quiet street", "startTimeMs": 1000],
                   ["text": "", "startTimeMs": 1000],
                   ["text": "The lamps return", "startTimeMs": 2000]],
         "provider": "fixture", "providerDisplayName": "Fixture provider",
         "language": "ar", "isRightToLeft": true]
    }
}
