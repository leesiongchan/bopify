import Testing
import Foundation
import BopifyDomain

@Suite("Playback recovery contract")
struct PlaybackRecoveryTests {
    @Test func identityAndReadinessDecodeWithNativeOccurrence() throws {
        let json = #"{"type":"connectionReady","outcome":"local","identity":{"trackUri":"spotify:track:x","trackUid":"second","contextUri":"spotify:playlist:p"}}"#
        let identity = PlaybackIdentity(trackURI: SpotifyURI("spotify:track:x")!, trackUID: "second", contextURI: "spotify:playlist:p")
        #expect(try JSONDecoder().decode(PlaybackEvent.self, from: Data(json.utf8)) == .connectionReady(.local(identity)))
        #expect(try JSONDecoder().decode(PlaybackEvent.self, from: Data(#"{"type":"connectionReady","outcome":"remote"}"#.utf8)) == .connectionReady(.remote))
        #expect(try JSONDecoder().decode(PlaybackEvent.self, from: Data(#"{"type":"connectionReady","outcome":"unavailable"}"#.utf8)) == .connectionReady(.unavailable))
    }

    @Test func malformedIdentityIsRejected() {
        #expect(throws: (any Error).self) { try JSONDecoder().decode(PlaybackIdentity.self, from: Data(#"{"trackUri":"oops"}"#.utf8)) }
    }

    @Test func recoveryConfigurationEncodesCrossLanguageKeysAndZeroVolume() throws {
        let snapshot = PlaybackRecoverySnapshot(wasActive: true, shouldResume: false, identity: nil, positionMs: 24, volume: 0, shuffleEnabled: false, repeatMode: .track)
        let config = PlaybackEngineConfiguration(deviceID: "stable", startup: .recovery, snapshot: snapshot)
        let data = try JSONEncoder().encode(config)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["deviceId"] as? String == "stable")
        #expect((json["snapshot"] as? [String: Any])?["volume"] as? Double == 0)
        #expect(try JSONDecoder().decode(PlaybackEngineConfiguration.self, from: data) == config)
    }
}
