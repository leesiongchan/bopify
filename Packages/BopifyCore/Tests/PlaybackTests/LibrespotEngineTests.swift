import Testing
import Foundation
@testable import BopifyPlayback
import BopifyDomain

@Suite("LibrespotEngine")
struct LibrespotEngineTests {
    /// The only real FFI path reachable without a Spotify account, so an over-release of the retained context traps here.
    /// The assertion stays loose because an offline machine yields `.networkUnavailable` where a rejected token yields `.authExpired`.
    @Test func createFailurePathReleasesTheContextWithoutCrashing() async {
        await #expect(throws: PlayerError.self) {
            _ = try await LibrespotEngine(accessToken: "not-a-real-token", deviceName: "Bopify Test",
                                          configuration: PlaybackEngineConfiguration(deviceID: "test-device", startup: .coldLaunch))
        }
    }

    /// `InvalidArgument` (-1), `Unknown` (-99) and unrecognised codes all fold to `.unknown`, because -1 is a caller bug
    /// with nothing useful to show a listener. Rust's `error.rs` tests read the same fixture.
    @Test func mapsTheSharedFFICodesOntoTheErrorTaxonomy() throws {
        let expected: [String: PlayerError] = [
            "invalidArgument": .unknown,
            "sessionLost": .playbackSessionLost,
            "authInvalid": .authExpired,
            "premiumRequired": .premiumRequired,
            "accountRestricted": .accountRestricted,
            "networkUnavailable": .networkUnavailable,
            "unknown": .unknown,
        ]
        let fixture = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "../../../../contracts/ffi-error-codes.json").standardized
        let codes = try JSONDecoder().decode([String: Int32].self, from: Data(contentsOf: fixture))
        #expect(Set(codes.keys) == Set(expected.keys))
        for (name, code) in codes { #expect(PlayerError(ffiCode: code) == expected[name], "\(name)") }
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
