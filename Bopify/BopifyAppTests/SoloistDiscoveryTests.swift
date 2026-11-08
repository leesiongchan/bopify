import Foundation
import Network
import Observation
import Testing

private nonisolated final class DiscoveryObservationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var changed = false
    func set() { lock.withLock { changed = true } }
    var value: Bool { lock.withLock { changed } }
}

@MainActor private final class DiscoveryFixture {
    let clock = LiveLyricTestClock()
    var updates: [(@MainActor (NWBrowser.State) -> Void)] = []
    var cancelled: [Int] = []
    var events: [(@MainActor (SoloistDiscovery.RecoveryEvent) -> Void)] = []
    var stoppedMonitors = 0

    func discovery() -> SoloistDiscovery {
        SoloistDiscovery(makeBrowser: {
            let id = self.updates.count
            return SoloistDiscovery.Browser(start: { self.updates.append($0) }, cancel: { self.cancelled.append(id) })
        }, observeRecovery: {
            self.events.append($0)
            return { self.stoppedMonitors += 1 }
        }, sleep: { try await self.clock.sleep(for: $0) })
    }
}

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

    @Test func initialReadinessIsObservableWithoutReportingGeneralRecovery() {
        let fixture = DiscoveryFixture(), discovery = fixture.discovery()
        var recoveries = 0
        discovery.start { recoveries += 1 }
        defer { discovery.stop() }
        #expect(!discovery.isReady)
        let changed = DiscoveryObservationFlag()
        withObservationTracking { _ = discovery.isReady } onChange: { changed.set() }
        fixture.updates[0](.ready)
        #expect(discovery.isReady && changed.value)
        #expect(recoveries == 0)
    }

    @Test func readinessResetsAcrossWaitingReplacementCancellationAndStop() {
        let fixture = DiscoveryFixture(), discovery = fixture.discovery()
        discovery.start()
        defer { discovery.stop() }
        fixture.updates[0](.ready)
        #expect(discovery.isReady)
        fixture.updates[0](.waiting(.dns(-65570)))
        #expect(!discovery.isReady)
        fixture.updates[0](.ready)
        #expect(discovery.isReady)
        fixture.updates[0](.failed(.dns(-65570)))
        #expect(!discovery.isReady)
        fixture.updates[0](.ready)
        #expect(!discovery.isReady, "A retired browser cannot restore readiness")
        fixture.events[0](.activated)
        #expect(!discovery.isReady)
        fixture.updates[1](.ready)
        #expect(discovery.isReady)
        discovery.stop()
        #expect(!discovery.isReady)
        fixture.updates[1](.ready)
        #expect(!discovery.isReady)
        discovery.start()
        fixture.updates[1](.ready)
        #expect(!discovery.isReady, "A prior run cannot make a fresh browser ready")
        fixture.updates[2](.ready)
        #expect(discovery.isReady)
        fixture.updates[2](.cancelled)
        #expect(!discovery.isReady)
    }

    @Test func failedBrowserRetriesWithBoundedBackoffAndReportsActualRecovery() async throws {
        let fixture = DiscoveryFixture(), discovery = fixture.discovery()
        var recoveries = 0
        discovery.start { recoveries += 1 }
        defer { discovery.stop() }
        fixture.updates[0](.ready)
        #expect(recoveries == 0, "Initial readiness must not restart setup")
        for (index, delay) in [1, 2, 4, 8].enumerated() {
            fixture.updates[index](.failed(.posix(.ENETDOWN)))
            #expect(discovery.state == .unavailable)
            try await liveLyricEventually { fixture.clock.pendingDelays == [.seconds(delay)] }
            #expect(fixture.updates.count == index + 1)
            fixture.clock.advance(by: .seconds(delay))
            try await liveLyricEventually { fixture.updates.count == index + 2 }
            fixture.updates[index](.ready)
            #expect(discovery.state == .unavailable && recoveries == 0, "A retired browser cannot recover setup")
        }
        fixture.updates[4](.failed(.dns(-65537)))
        for _ in 0..<20 { await Task.yield() }
        #expect(fixture.clock.pendingDelays.isEmpty && fixture.updates.count == 5)
        fixture.events[0](.activated)
        #expect(fixture.updates.count == 6 && recoveries == 1)
        fixture.updates[5](.ready)
        #expect(discovery.state == .browsing && recoveries == 2)
        fixture.updates[5](.ready)
        #expect(recoveries == 2)
    }

    @Test func deniedPermissionWaitsForAnExternalRecoveryOpportunity() async throws {
        let fixture = DiscoveryFixture(), discovery = fixture.discovery()
        var recoveries = 0
        discovery.start { recoveries += 1 }
        defer { discovery.stop() }
        fixture.updates[0](.failed(.dns(-65570)))
        for _ in 0..<20 { await Task.yield() }
        #expect(discovery.state == .denied)
        #expect(fixture.clock.pendingDelays.isEmpty && fixture.updates.count == 1)
        fixture.events[0](.activated)
        try #require(fixture.updates.count == 2 && recoveries == 1)
        fixture.updates[1](.ready)
        #expect(discovery.state == .browsing && recoveries == 2)
    }

    @Test func waitingBrowserCanRecoverWithoutReplacementOrAnInitialReadyCallback() {
        let fixture = DiscoveryFixture(), discovery = fixture.discovery()
        var recoveries = 0
        discovery.start { recoveries += 1 }
        defer { discovery.stop() }
        fixture.updates[0](.waiting(.posix(.ENETDOWN)))
        #expect(discovery.state == .unavailable)
        fixture.updates[0](.ready)
        #expect(discovery.state == .browsing && recoveries == 1)
        #expect(fixture.updates.count == 1 && fixture.cancelled.isEmpty)
    }

    @Test func networkRestorationAndActivationKeepAHealthyBrowser() {
        let fixture = DiscoveryFixture(), discovery = fixture.discovery()
        var recoveries = 0
        discovery.start { recoveries += 1 }
        defer { discovery.stop() }
        fixture.updates[0](.ready)
        fixture.events[0](.networkChanged(true))
        fixture.events[0](.networkChanged(true))
        #expect(recoveries == 0)
        fixture.events[0](.networkChanged(false))
        fixture.events[0](.networkChanged(true))
        fixture.events[0](.activated)
        #expect(recoveries == 2)
        #expect(fixture.updates.count == 1 && fixture.cancelled.isEmpty)
    }

    @Test func stopCancelsOwnedRetryAndMonitorsAndRejectsEveryLateGeneration() async throws {
        let fixture = DiscoveryFixture(), discovery = fixture.discovery()
        var recoveries = 0
        discovery.start { recoveries += 1 }
        fixture.updates[0](.failed(.posix(.ENETDOWN)))
        try await liveLyricEventually { !fixture.clock.pendingDelays.isEmpty }
        discovery.stop()
        try await liveLyricEventually { fixture.clock.pendingDelays.isEmpty }
        #expect(fixture.stoppedMonitors == 1 && fixture.cancelled == [0])
        fixture.updates[0](.ready)
        fixture.events[0](.activated)
        fixture.events[0](.networkChanged(false))
        fixture.events[0](.networkChanged(true))
        fixture.clock.advance(by: .seconds(100))
        #expect(discovery.state == .idle && recoveries == 0 && fixture.updates.count == 1)
        discovery.start { recoveries += 1 }
        fixture.updates[0](.failed(.dns(-65570)))
        fixture.events[0](.activated)
        #expect(discovery.state == .browsing && recoveries == 0 && fixture.updates.count == 2)
        discovery.stop()
        #expect(fixture.stoppedMonitors == 2 && fixture.cancelled == [0, 1])
    }
}
