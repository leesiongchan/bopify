import Foundation

enum ProbeReason: String, Codable, Sendable, Error {
    case accountMismatch, missingAccountID, noNewDevice, ambiguousDevice, restrictedDevice
    case observationLost, staleObservation, ownershipChanged, playbackMismatch, notAdvancing
    case generationChanged, notPaired, invalidInput, invalidArtifact, trustFailed, invalidEndpoint
    case timeout, cancelled, processFailed, invalidResponse, httpStatus, rateLimited
    case consentDenied, companionFailed, servicesUnavailable, notRun
}

struct ProbeError: Error, Sendable {
    let reason: ProbeReason
    var status: Int? = nil
    var retryAfter: Double? = nil
}

enum ProbeVerdict: Codable, Equatable, Sendable {
    case passed
    case failed(reason: ProbeReason)
    case inconclusive(reason: ProbeReason)
}

struct ProbeDevice: Hashable, Decodable, Sendable {
    var id: String?
    var name: String
    var isActive: Bool
    var isRestricted: Bool

    enum CodingKeys: String, CodingKey {
        case id, name
        case isActive = "is_active", isRestricted = "is_restricted"
    }
}

struct ProbePlayback: Sendable {
    var deviceID: String?
    var itemURI: String?
    var contextURI: String?
    var isPlaying: Bool
    var positionMs: Double
    var observedAt: Date
}

struct SoloistProbeSnapshot: Sendable {
    var generation: UUID
    var authGeneration: UInt64
    var paired: Bool
    var active: Bool
    var itemURI: String?
    var positionMs: Double
    var playing: Bool
    var observedAt: Date
}

struct ProbeSample: Sendable {
    var soloist: SoloistProbeSnapshot
    var web: ProbePlayback
}

struct CorrelationEvidence: Sendable {
    var streamingAccountID: String?
    var webAccountID: String?
    var beforeDevices: Set<ProbeDevice>
    var afterDevices: Set<ProbeDevice>
    var expectedName: String
    var generation: UUID
    var knownDeviceID: String?
    var processRunning: Bool
    var socketConnected: Bool
    var samples: [ProbeSample]
    var now: Date

    var candidates: [ProbeDevice] {
        let baseline = Set(beforeDevices.compactMap(\.id))
        return afterDevices.filter { device in
            guard device.name == expectedName, let id = device.id, !id.isEmpty else { return false }
            return knownDeviceID.map { id == $0 } ?? !baseline.contains(id)
        }
    }
}

func evaluateCorrelation(_ evidence: CorrelationEvidence) -> ProbeVerdict {
    guard let first = evidence.streamingAccountID, !first.isEmpty,
          let second = evidence.webAccountID, !second.isEmpty else {
        return .inconclusive(reason: .missingAccountID)
    }
    guard first == second else { return .failed(reason: .accountMismatch) }
    guard evidence.processRunning, evidence.socketConnected else { return .inconclusive(reason: .observationLost) }
    let candidates = evidence.candidates
    guard !candidates.isEmpty else { return .inconclusive(reason: .noNewDevice) }
    guard candidates.count == 1 else { return .inconclusive(reason: .ambiguousDevice) }
    let device = candidates[0]
    guard !device.isRestricted else { return .inconclusive(reason: .restrictedDevice) }
    guard device.isActive else { return .inconclusive(reason: .ownershipChanged) }
    guard evidence.samples.count >= 2, let earliest = evidence.samples.first,
          let latest = evidence.samples.last else { return .inconclusive(reason: .notAdvancing) }
    for sample in evidence.samples {
        let local = sample.soloist, web = sample.web
        guard local.generation == evidence.generation,
              local.authGeneration == earliest.soloist.authGeneration else {
            return .inconclusive(reason: .generationChanged)
        }
        guard local.paired else { return .inconclusive(reason: .notPaired) }
        guard local.active, web.deviceID == device.id else { return .inconclusive(reason: .ownershipChanged) }
        let ages = [evidence.now.timeIntervalSince(local.observedAt), evidence.now.timeIntervalSince(web.observedAt)]
        guard ages.allSatisfy({ $0 >= 0 && $0 <= 2 }) else { return .inconclusive(reason: .staleObservation) }
        guard let item = local.itemURI, !item.isEmpty, item == web.itemURI,
              local.positionMs.isFinite, web.positionMs.isFinite, local.positionMs >= 0, web.positionMs >= 0,
              local.playing, web.isPlaying else { return .inconclusive(reason: .playbackMismatch) }
        let adjustedLocal = local.positionMs + evidence.now.timeIntervalSince(local.observedAt) * 1000
        let adjustedWeb = web.positionMs + evidence.now.timeIntervalSince(web.observedAt) * 1000
        guard abs(adjustedLocal - adjustedWeb) <= 2000 else { return .inconclusive(reason: .playbackMismatch) }
    }
    guard latest.soloist.observedAt > earliest.soloist.observedAt,
          latest.web.observedAt > earliest.web.observedAt,
          latest.soloist.itemURI == earliest.soloist.itemURI,
          latest.soloist.positionMs > earliest.soloist.positionMs,
          latest.web.positionMs > earliest.web.positionMs else { return .inconclusive(reason: .notAdvancing) }
    return .passed
}

struct ProbeReport: Codable, Sendable {
    var schemaVersion = 1
    var platform = "macOS-arm64"
    var soloistVersion = "unknown"
    var correlation: ProbeVerdict
    var restart: ProbeVerdict = .inconclusive(reason: .notRun)
    var companion: ProbeVerdict = .inconclusive(reason: .notRun)
    var httpStatus: Int?
    var retryAfterSeconds: Double?
    var samples = 0
}
