import Testing
import Foundation
@testable import BopifyPlayback
import BopifyDomain

@Suite("LibrespotEngine")
struct LibrespotEngineTests {
    /// The only end-to-end FFI path reachable without a Spotify account: a
    /// real `bopify_engine_create`, with a real callback pointer and a real
    /// retained context, that fails and takes the throw path.
    ///
    /// The value is in the execution, not the assertion: an over-release on
    /// that path would take the bridge's refcount to zero mid-scope and very
    /// likely trap. The assertion itself is weak on purpose — `init` has one
    /// throw site and it throws `PlayerError(ffiCode:)` by construction, so
    /// this can only fail if create succeeds or the process dies, and there
    /// is no honest way to tighten it: an offline machine legitimately yields
    /// `.networkUnavailable` where a rejected token yields `.authExpired`.
    /// It cannot detect a *missing* release, which is the likelier mistake,
    /// because that is a silent leak.
    @Test func createFailurePathReleasesTheContextWithoutCrashing() async {
        await #expect(throws: PlayerError.self) {
            _ = try await LibrespotEngine(accessToken: "not-a-real-token", deviceName: "Bopify Test")
        }
    }

    /// Characterises the whole `BopifyError` → `PlayerError` mapping, one
    /// case per Rust code. The mapping is not injective and is not meant to
    /// be: `InvalidArgument` (-1), `Unknown` (-99) and anything unrecognised
    /// all fold to `.unknown`, because -1 is a caller bug with nothing useful
    /// to show a listener.
    @Test func mapsFFICodesOntoTheErrorTaxonomy() {
        #expect(PlayerError(ffiCode: -1) == .unknown)
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
