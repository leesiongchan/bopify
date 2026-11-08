import Foundation
import Testing
@testable import BopifyPlayback

@Test func soloistBonjourRequiresTheExpectedSDKIdentity() throws {
    let valid = Data(#"{"status":101,"remoteName":"Bopify fixture","deviceID":"owned-device"}"#.utf8)
    #expect(try SoloistPairingIdentity.validate(valid, name: "Bopify fixture") == "owned-device")
    #expect(throws: SoloistPlaybackError.discoveryUnavailable) {
        try SoloistPairingIdentity.validate(valid, name: "Another device")
    }
    for value in [#"{"status":202,"remoteName":"Bopify fixture","deviceID":"owned-device"}"#,
                  #"{"status":101,"remoteName":"Bopify fixture"}"#, #"[]"#] {
        #expect(throws: SoloistPlaybackError.discoveryUnavailable) {
            try SoloistPairingIdentity.validate(Data(value.utf8), name: "Bopify fixture")
        }
    }
}

@Test func soloistBonjourRejectsOversizedIdentityReplies() {
    #expect(throws: SoloistPlaybackError.discoveryUnavailable) {
        try SoloistPairingIdentity.validate(Data(repeating: 32, count: 65_537), name: "Bopify fixture")
    }
}
