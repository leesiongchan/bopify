import Testing
import Foundation
@testable import BopifyPlayback
import BopifyDomain

@Suite("FFI errors")
struct FFIErrorTests {
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

}
