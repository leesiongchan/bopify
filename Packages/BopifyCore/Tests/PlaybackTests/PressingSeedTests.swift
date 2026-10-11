import Testing
import BopifyPlayback

@Suite("PressingSeed") struct PressingSeedTests {
    @Test(arguments: [
        ("spotify:track:abc", UInt64(2443243037788774046), Float(3742)),
        ("spotify:track:def", UInt64(4257243709808024385), Float(2881)),
        ("spotify:track:é", UInt64(17385341988102125798), Float(2278)),
    ]) func uriHasStableUTF8Seed(uri: String, hash: UInt64, offset: Float) {
        #expect(PressingSeed.hash(uri) == hash)
        #expect(PressingSeed.offset(uri) == offset)
    }

    @Test func differentSongsHaveDifferentNoiseOffsets() {
        #expect(PressingSeed.offset("spotify:track:abc") != PressingSeed.offset("spotify:track:def"))
        for index in 0..<100 {
            let offset = PressingSeed.offset("spotify:track:preview\(index)")
            #expect(offset >= 0 && offset < 4096)
            #expect(offset.rounded() == offset)
        }
    }
}
