import Foundation
import Testing
@testable import SoloistFeasibility

private let instant = Date(timeIntervalSince1970: 10_000)
private let generation = UUID()

func validEvidence() -> CorrelationEvidence {
    let device = ProbeDevice(id: "owned-device", name: "probe-name", isActive: true, isRestricted: false)
    func sample(_ offset: Double) -> ProbeSample {
        let date = instant.addingTimeInterval(offset)
        return ProbeSample(
            soloist: SoloistProbeSnapshot(generation: generation, authGeneration: 1, paired: true,
                active: true, itemURI: "spotify:track:1111111111111111111111", positionMs: 10_000 + offset * 1000,
                playing: true, observedAt: date),
            web: ProbePlayback(deviceID: "owned-device", itemURI: "spotify:track:1111111111111111111111",
                contextURI: nil, isPlaying: true, positionMs: 10_000 + offset * 1000, observedAt: date))
    }
    return CorrelationEvidence(streamingAccountID: "same-account", webAccountID: "same-account",
        beforeDevices: [], afterDevices: [device], expectedName: "probe-name", generation: generation,
        knownDeviceID: nil, processRunning: true, socketConnected: true,
        samples: [sample(-1), sample(0)], now: instant)
}

@Test func freshMatchingObservationsPass() {
    #expect(evaluateCorrelation(validEvidence()) == .passed)
}

@Test func aNameMatchWithoutANewDeviceIsInconclusive() {
    var e = validEvidence()
    e.beforeDevices = e.afterDevices
    #expect(evaluateCorrelation(e) == .inconclusive(reason: .noNewDevice))
}

@Test func differentAccountsCannotBeCombined() {
    var e = validEvidence()
    e.webAccountID = "another-account"
    #expect(evaluateCorrelation(e) == .failed(reason: .accountMismatch))
}

@Test func missingAccountIDIsNotAUsernameFallback() {
    var e = validEvidence()
    e.streamingAccountID = nil
    #expect(evaluateCorrelation(e) == .inconclusive(reason: .missingAccountID))
}

@Test func ambiguousDevicesCannotBeTargeted() {
    var e = validEvidence()
    e.afterDevices.insert(ProbeDevice(id: "other", name: "probe-name", isActive: false, isRestricted: false))
    #expect(evaluateCorrelation(e) == .inconclusive(reason: .ambiguousDevice))
}

@Test func nullOrRestrictedIDsCannotBeTargeted() {
    for device in [ProbeDevice(id: nil, name: "probe-name", isActive: true, isRestricted: false),
                   ProbeDevice(id: "owned-device", name: "probe-name", isActive: true, isRestricted: true)] {
        var e = validEvidence()
        e.afterDevices = [device]
        #expect(evaluateCorrelation(e) != .passed)
    }
}

@Test func staleFutureAndNonfinitePositionsCannotPass() {
    for changedDate in [instant.addingTimeInterval(-3), instant.addingTimeInterval(1)] {
        var e = validEvidence()
        e.samples[1].soloist.observedAt = changedDate
        #expect(evaluateCorrelation(e) != .passed)
    }
    var e = validEvidence()
    e.samples[1].web.positionMs = .nan
    #expect(evaluateCorrelation(e) != .passed)
}

@Test func mismatchedTrackAndPositionCannotPass() {
    var e = validEvidence()
    e.samples[1].web.itemURI = "spotify:track:2222222222222222222222"
    #expect(evaluateCorrelation(e) != .passed)
    e = validEvidence()
    e.samples[1].soloist.positionMs += 3000
    #expect(evaluateCorrelation(e) != .passed)
}

@Test func remoteTakeoverAndUnpairingInvalidateEvidence() {
    var e = validEvidence()
    e.samples[1].web.deviceID = "phone"
    #expect(evaluateCorrelation(e) != .passed)
    e = validEvidence()
    e.samples[1].soloist.paired = false
    #expect(evaluateCorrelation(e) != .passed)
}

@Test func processAndAuthenticationGenerationsCannotBeReused() {
    var e = validEvidence()
    e.samples[1].soloist.generation = UUID()
    #expect(evaluateCorrelation(e) != .passed)
    e = validEvidence()
    e.samples[1].soloist.authGeneration = 2
    #expect(evaluateCorrelation(e) != .passed)
}

@Test func missingObservationIsNotAudioFailure() {
    var e = validEvidence()
    e.socketConnected = false
    #expect(evaluateCorrelation(e) == .inconclusive(reason: .observationLost))
}

@Test func stationaryPlaybackCannotProveAdvancement() {
    var e = validEvidence()
    e.samples[1].soloist.positionMs = e.samples[0].soloist.positionMs
    #expect(evaluateCorrelation(e) != .passed)
}

@Test func aPreviouslyCorrelatedIDCanBeRevalidatedAfterRestart() {
    var e = validEvidence()
    e.beforeDevices = e.afterDevices
    e.knownDeviceID = "owned-device"
    #expect(evaluateCorrelation(e) == .passed)
}

@Test func reportDoesNotContainAccountsDevicesOrContent() throws {
    let report = ProbeReport(correlation: evaluateCorrelation(validEvidence()))
    let text = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
    for value in ["same-account", "owned-device", "spotify:track:", "access_token", "api_key"] {
        #expect(!text.contains(value))
    }
}

@Test func companionSuccessRequiresEveryServiceToActuallyReturnData() throws {
    let report = try JSONDecoder().decode(CompanionReport.self, from: Data(#"{"schemaVersion":1,"elapsedMs":12,"lyrics":{"outcome":"available","count":3},"radio":{"outcome":"absent","count":0},"artist":{"outcome":"available","count":4},"failure":null}"#.utf8))
    #expect(!report.allAvailable)
    #expect(throws: ProbeError.self) {
        try CompanionReport.decode(Data(#"{"schemaVersion":2,"elapsedMs":0,"lyrics":{"outcome":"available","count":1},"radio":{"outcome":"available","count":1},"artist":{"outcome":"available","count":1}}"#.utf8))
    }
}

@Test func companionReportDoesNotAcceptUnknownSensitiveFields() {
    let data = Data(#"{"schemaVersion":1,"elapsedMs":1,"lyrics":{"outcome":"available","count":1},"radio":{"outcome":"available","count":1},"artist":{"outcome":"available","count":1},"failure":null,"access_token":"sentinel"}"#.utf8)
    #expect(throws: ProbeError.self) { try CompanionReport.decode(data) }
}

@Test func onlyOneExecutableForTheCoreTestTargetMayBeSelected() throws {
    let valid = Data(#"{"reason":"compiler-artifact","target":{"name":"bopify_core"},"profile":{"test":true},"executable":"/tmp/owned-test"}"#.utf8)
    #expect(try ProbeEvidence.testExecutable(from: valid).path == "/tmp/owned-test")
    #expect(throws: ProbeError.self) { try ProbeEvidence.testExecutable(from: valid + Data("\n".utf8) + valid) }
    #expect(throws: ProbeError.self) { try ProbeEvidence.testExecutable(from: Data(#"{"reason":"build-finished","success":true}"#.utf8)) }
}
