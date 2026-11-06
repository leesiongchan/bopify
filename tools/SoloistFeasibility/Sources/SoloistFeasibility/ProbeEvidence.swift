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
    var services: CompanionReport?
}

struct CompanionReport: Codable, Sendable {
    enum Outcome: String, Codable, Sendable { case available, absent, network, unavailable }
    enum Failure: String, Codable, Sendable {
        case missingInput, inputTooLarge, invalidInput, invalidTrack, missingToken
        case loginFailed, loginTimeout, runtimeFailed, reportFailed
    }
    struct Service: Codable, Sendable {
        let outcome: Outcome
        let count: Int
    }
    let schemaVersion: Int
    let lyrics: Service
    let radio: Service
    let artist: Service
    let elapsedMs: UInt64
    let failure: Failure?

    var allAvailable: Bool {
        schemaVersion == 1 && failure == nil && [lyrics, radio, artist].allSatisfy { $0.outcome == .available && $0.count > 0 }
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 16_384,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["schemaVersion", "lyrics", "radio", "artist", "elapsedMs", "failure"]),
              let report = try? JSONDecoder().decode(Self.self, from: data), report.schemaVersion == 1,
              [report.lyrics, report.radio, report.artist].allSatisfy({ (0...10_000).contains($0.count) }) else {
            throw ProbeError(reason: .invalidResponse)
        }
        for key in ["lyrics", "radio", "artist"] {
            guard let service = object[key] as? [String: Any], Set(service.keys) == ["outcome", "count"] else {
                throw ProbeError(reason: .invalidResponse)
            }
        }
        return report
    }
}

enum ProbeEvidence {
    static func testExecutable(from messages: Data) throws -> URL {
        var candidates: [String] = []
        for line in messages.split(separator: 10) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  object["reason"] as? String == "compiler-artifact",
                  let target = object["target"] as? [String: Any], target["name"] as? String == "bopify_core",
                  let profile = object["profile"] as? [String: Any], profile["test"] as? Bool == true,
                  let executable = object["executable"] as? String, executable.hasPrefix("/") else { continue }
            candidates.append(executable)
        }
        guard candidates.count == 1 else { throw ProbeError(reason: .companionFailed) }
        return URL(fileURLWithPath: candidates[0]).standardizedFileURL
    }

    static func prepareCompanion(repository: URL) async throws -> URL {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        guard let cargo = paths.map({ URL(fileURLWithPath: String($0)).appendingPathComponent("cargo") })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw ProbeError(reason: .companionFailed)
        }
        var environment = ProcessInfo.processInfo.environment
        let target = repository.appendingPathComponent("rust/target").resolvingSymlinksInPath()
        environment["CARGO_TARGET_DIR"] = target.path
        let build = try ProbeChild(executable: cargo, arguments: ["test", "--manifest-path", "rust/Cargo.toml", "--locked",
            "-p", "bopify-core", "--lib", "soloist_feasibility::live_data_session", "--no-run", "--message-format=json"],
            directory: repository, environment: environment)
        let result = try await build.wait(seconds: 600)
        guard result.status == 0 else { throw ProbeError(reason: .companionFailed) }
        let executable = try testExecutable(from: result.output).resolvingSymlinksInPath()
        guard executable.path.hasPrefix(target.path + "/"), FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ProbeError(reason: .companionFailed)
        }
        return executable
    }

    static func runCompanion(accessToken: String, trackURI: String, executable: URL) async throws -> CompanionReport {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bopify-companion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("result.json")
        let input = try JSONSerialization.data(withJSONObject: ["access_token": accessToken, "track_uri": trackURI])
        guard input.count <= 16_384 else { throw ProbeError(reason: .invalidInput) }
        var environment = ProcessInfo.processInfo.environment
        environment["BOPIFY_SOLOIST_PROBE_RESULT_PATH"] = output.path
        let child = try ProbeChild(executable: executable,
            arguments: ["soloist_feasibility::live_data_session", "--ignored", "--exact", "--nocapture", "--test-threads=1"],
            environment: environment, input: input)
        let result = try await child.wait(seconds: 150)
        guard result.status == 0 else { throw ProbeError(reason: .companionFailed) }
        return try CompanionReport.decode(readOwnedFile(output, limit: 16_384, mode: 0o600))
    }
}

func monitorCompanion(probe: OwnedSoloistProbe, http: ProbeObservation, webToken: String,
    evidence initial: CorrelationEvidence) async throws {
    let deadline = Date().addingTimeInterval(30)
    let expectedIDs = Set(initial.afterDevices.compactMap(\.id))
    let expectedAuth = initial.samples.last?.soloist.authGeneration
    var evidence = initial
    evidence.knownDeviceID = initial.candidates.first?.id
    guard evidence.knownDeviceID != nil else { throw ProbeError(reason: .ambiguousDevice) }
    while Date() < deadline {
        async let local = probe.snapshot()
        async let remote = http.playback(accessToken: webToken)
        async let discovered = http.devices(accessToken: webToken)
        let (snapshot, playback, devices) = try await (local, remote, discovered)
        guard let playback, snapshot.paired, snapshot.active, playback.deviceID == evidence.knownDeviceID,
              snapshot.authGeneration == expectedAuth else { throw ProbeError(reason: .ownershipChanged) }
        guard Set(devices.compactMap(\.id)).isSubset(of: expectedIDs) else { throw ProbeError(reason: .ambiguousDevice) }
        if evidence.samples.last?.soloist.itemURI != snapshot.itemURI { evidence.samples = [] }
        evidence.samples.append(ProbeSample(soloist: snapshot, web: playback))
        evidence.samples = Array(evidence.samples.suffix(2))
        evidence.afterDevices = devices
        evidence.processRunning = await probe.child.isRunning
        evidence.now = .now
        let verdict = evaluateCorrelation(evidence)
        if evidence.samples.count >= 2 && verdict != .passed { throw ProbeError(reason: .observationLost) }
        try await Task.sleep(for: .milliseconds(500))
    }
}
