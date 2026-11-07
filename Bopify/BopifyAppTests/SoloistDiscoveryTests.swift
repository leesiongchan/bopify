import Network
import Testing

@MainActor @Suite("Soloist discovery")
struct SoloistDiscoveryTests {
    @Test func policyDenialHasItsOwnRecoveryState() {
        #expect(SoloistDiscovery.status(for: .waiting(.dns(-65570))) == .denied)
        #expect(SoloistDiscovery.status(for: .failed(.dns(-65570))) == .denied)
    }

    @Test func otherNetworkFailuresDoNotClaimPermissionWasDenied() {
        #expect(SoloistDiscovery.status(for: .waiting(.posix(.ENETDOWN))) == .unavailable)
        #expect(SoloistDiscovery.status(for: .failed(.dns(-65537))) == .unavailable)
        #expect(SoloistDiscovery.status(for: .ready) == .browsing)
        #expect(SoloistDiscovery.status(for: .cancelled) == .idle)
    }
}
