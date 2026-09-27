import Testing
import Foundation
@testable import BopifyDomain

@Suite("PlaybackEvent decoding")
struct PlaybackEventTests {
    private func decode(_ json: String) throws -> PlaybackEvent {
        try JSONDecoder().decode(PlaybackEvent.self, from: Data(json.utf8))
    }

    @Test func decodesPlaying() throws {
        #expect(try decode(#"{"type":"playing","positionMs":1000}"#) == .playing(positionMs: 1000))
    }

    @Test func decodesTrackChanged() throws {
        let json = #"""
        {"type":"trackChanged","trackUri":"spotify:track:abc","title":"Title",
         "artists":["A","B"],"albumTitle":"Album","artworkUrl":null,"durationMs":240000}
        """#
        guard case let .trackChanged(track) = try decode(json) else {
            Issue.record("expected trackChanged"); return
        }
        #expect(track.title == "Title")
        #expect(track.artists.map(\.name) == ["A", "B"])
        #expect(track.durationMs == 240_000)
        #expect(track.artwork == nil)
        #expect(track.uri.id == "abc")
    }

    @Test func decodesActiveDeviceChanged() throws {
        #expect(try decode(#"{"type":"activeDeviceChanged","isActive":false}"#) == .activeDeviceChanged(isActive: false))
    }

    @Test func decodesFailureIntoTheErrorTaxonomy() throws {
        let json = #"{"type":"failed","code":-4,"message":"Spotify Premium is required"}"#
        #expect(try decode(json) == .failed(.premiumRequired))
    }

    @Test func mapsUnrecognisedCodesToUnknownRatherThanThrowing() throws {
        #expect(try decode(#"{"type":"failed","code":-12345,"message":"?"}"#) == .failed(.unknown))
    }

    @Test func throwsOnAnUnrecognisedEventType() {
        #expect(throws: (any Error).self) { try decode(#"{"type":"teleported"}"#) }
    }

    @Test func decodesVolumeAtFullScale() throws {
        #expect(try decode(#"{"type":"volumeChanged","volume":65535}"#) == .volumeChanged(volume: 1.0))
    }

    @Test func decodesVolumeAtZero() throws {
        #expect(try decode(#"{"type":"volumeChanged","volume":0}"#) == .volumeChanged(volume: 0.0))
    }

    @Test func normalisesVolumeAgainstUInt16Max() throws {
        guard case let .volumeChanged(volume) = try decode(#"{"type":"volumeChanged","volume":32768}"#) else {
            Issue.record("expected volumeChanged"); return
        }
        // Divisor spelled as a literal rather than read from UInt16.max, so this
        // pins the value independently of the implementation. A divisor of 65536
        // yields exactly 0.5 and fails here.
        #expect(volume == 32768.0 / 65535.0)
    }

    @Test func decodesEveryStartupOutcome() throws {
        #expect(try decode(#"{"type":"startupResolved","outcome":"restored"}"#) == .startupResolved(.restored))
        #expect(try decode(#"{"type":"startupResolved","outcome":"likedSongs"}"#) == .startupResolved(.likedSongs))
        #expect(try decode(#"{"type":"startupResolved","outcome":"nothing"}"#) == .startupResolved(.nothing))
        #expect(try decode(#"{"type":"startupResolved","outcome":"remote","deviceName":"iPhone"}"#)
                == .startupResolved(.remote(deviceName: "iPhone")))
    }

    @Test func rejectsAnUnknownOutcomeAndARemoteWithoutADevice() {
        #expect(throws: (any Error).self) { try decode(#"{"type":"startupResolved","outcome":"teleported"}"#) }
        #expect(throws: (any Error).self) { try decode(#"{"type":"startupResolved","outcome":"remote"}"#) }
    }

    @Test func decodesARemoteWithAndWithoutMetadata() throws {
        let json = #"""
        {"type":"remotePlayback","remote":{"deviceName":"iPhone","trackUri":"spotify:track:abc",
         "track":{"trackUri":"spotify:track:abc","title":"Title","artists":["A"],"albumTitle":null,"artworkUrl":null,"durationMs":200000},
         "isPlaying":true,"positionMs":7500,"durationMs":200000}}
        """#
        guard case let .remotePlayback(remote?) = try decode(json) else {
            Issue.record("expected a remote"); return
        }
        #expect(remote.deviceName == "iPhone")
        #expect(remote.trackURI.id == "abc")
        #expect(remote.track?.title == "Title")
        #expect(remote.isPlaying)
        #expect(remote.positionMs == 7500)
        #expect(remote.durationMs == 200_000)
        let bare = #"{"type":"remotePlayback","remote":{"deviceName":"iPhone","trackUri":"spotify:track:abc","track":null,"isPlaying":false,"positionMs":0,"durationMs":0}}"#
        guard case let .remotePlayback(withoutMetadata?) = try decode(bare) else {
            Issue.record("expected a remote"); return
        }
        #expect(withoutMetadata.track == nil)
        #expect(try decode(#"{"type":"remotePlayback","remote":null}"#) == .remotePlayback(nil))
    }

    @Test func rejectsARemoteWithAMalformedTrackURI() {
        #expect(throws: (any Error).self) {
            try decode(#"{"type":"remotePlayback","remote":{"deviceName":"iPhone","trackUri":"nope","track":null,"isPlaying":false,"positionMs":0,"durationMs":0}}"#)
        }
    }
}
