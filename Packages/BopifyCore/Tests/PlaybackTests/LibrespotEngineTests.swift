import Testing
import Foundation
@testable import BopifyPlayback
import BopifyDomain

@Suite("LibrespotEngine")
struct LibrespotEngineTests {
    /// The only end-to-end FFI path reachable without a Spotify account:
    /// a real `bopify_engine_create` that fails. Which case comes back
    /// depends on the machine — a rejected token, no network, or an
    /// unclassifiable librespot failure — so this pins the taxonomy, not the
    /// verdict. It also exercises the throw path that has to hand the
    /// retained context back.
    @Test func rejectsAnInvalidTokenWithATypedError() async {
        await #expect(throws: PlayerError.self) {
            _ = try await LibrespotEngine(accessToken: "not-a-real-token", deviceName: "Bopify Test")
        }
    }

    @Test func mapsEveryFFICodeToADistinctError() {
        #expect(PlayerError(ffiCode: -2) == .playbackSessionLost)
        #expect(PlayerError(ffiCode: -3) == .authExpired)
        #expect(PlayerError(ffiCode: -4) == .premiumRequired)
        #expect(PlayerError(ffiCode: -5) == .networkUnavailable)
        #expect(PlayerError(ffiCode: -99) == .unknown)
        #expect(PlayerError(ffiCode: 12345) == .unknown)
    }

    @Test func scalesVolumeOntoLibrespotsUInt16Scale() {
        #expect(LibrespotEngine.scaledVolume(0) == 0)
        #expect(LibrespotEngine.scaledVolume(1) == UInt16.max)
        #expect(LibrespotEngine.scaledVolume(0.5) == 32768)
    }

    /// A slider cannot produce these, but the clamp answering NaN with full
    /// volume would be a nasty way to find that out.
    @Test func clampsVolumeOutsideTheUnitRange() {
        #expect(LibrespotEngine.scaledVolume(-1) == 0)
        #expect(LibrespotEngine.scaledVolume(2) == UInt16.max)
        #expect(LibrespotEngine.scaledVolume(.nan) == 0)
    }

    /// The command side multiplies by 65535 and the event decoder divides by
    /// it; nothing but a round trip catches the two drifting apart.
    @Test func volumeSurvivesARoundTripThroughTheEventDecoder() throws {
        let raw = LibrespotEngine.scaledVolume(0.25)
        let json = Data(#"{"type":"volumeChanged","volume":\#(raw)}"#.utf8)
        let event = try JSONDecoder().decode(PlaybackEvent.self, from: json)
        guard case let .volumeChanged(volume) = event else {
            Issue.record("expected volumeChanged")
            return
        }
        // One step on the u16 scale is the most a round trip can lose.
        #expect(abs(volume - 0.25) < 1.0 / Double(UInt16.max))
    }
}
