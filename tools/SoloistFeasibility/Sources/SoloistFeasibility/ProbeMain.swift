import BopifyAuth
import BopifyPlayback
import Darwin
import Foundation

struct ProbeOptions: Sendable {
    let executable: URL?
    let keyFile: URL?
    let clientID: String?
    let report: URL?
    let installOnly: Bool

    static func parse(_ arguments: [String]) throws -> Self {
        let flags = ["--soloist", "--key-file", "--client-id", "--report"]
        var values: [String: String] = [:]
        var installOnly = false
        var index = 0
        while index < arguments.count {
            if arguments[index] == "--install-only" {
                guard !installOnly else { throw ProbeError(reason: .invalidInput) }
                installOnly = true
                index += 1
                continue
            }
            guard index + 1 < arguments.count else { throw ProbeError(reason: .invalidInput) }
            let flag = arguments[index], value = arguments[index + 1]
            guard flags.contains(flag), values[flag] == nil, !value.isEmpty else { throw ProbeError(reason: .invalidInput) }
            values[flag] = value
            index += 2
        }
        let id = values["--client-id"].flatMap(LibraryAuthorization.normalized)
        guard installOnly ? values["--soloist"] == nil : values["--key-file"] != nil && id != nil else {
            throw ProbeError(reason: .invalidInput)
        }
        return Self(executable: values["--soloist"].map { URL(fileURLWithPath: $0).standardizedFileURL },
            keyFile: values["--key-file"].map { URL(fileURLWithPath: $0).standardizedFileURL }, clientID: id,
            report: values["--report"].map { URL(fileURLWithPath: $0).standardizedFileURL }, installOnly: installOnly)
    }
}

func probeMessage(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// No mutating control is sent: the listener selects the probe and starts music in Spotify.
func collectCorrelation(probe: OwnedSoloistProbe, http: ProbeObservation, streamingAccountID: String,
    webAccountID: String, webToken: String, baseline: Set<ProbeDevice>, name: String,
    knownDeviceID: String? = nil) async throws -> CorrelationEvidence {
    let deadline = Date().addingTimeInterval(300)
    var samples: [ProbeSample] = []
    var attempt = CorrelationAttempt()
    var lastReason = ProbeReason.timeout
    while Date() < deadline {
        try Task.checkCancellation()
        do {
            let (sample, discovered) = try await readProbeState(probe: probe, http: http, webToken: webToken,
                expectedID: attempt.deviceID, expectedAuth: attempt.authGeneration)
            guard let sample else {
                try attempt.record(nil, candidateID: nil)
                try await Task.sleep(for: .milliseconds(500))
                continue
            }
            if let previous = samples.last, previous.soloist.itemURI != sample.soloist.itemURI {
                samples = []
            }
            samples.append(sample)
            samples = Array(samples.suffix(2))
            let evidence = CorrelationEvidence(streamingAccountID: streamingAccountID, webAccountID: webAccountID,
                beforeDevices: baseline, afterDevices: discovered, expectedName: name, generation: probe.generation,
                knownDeviceID: knownDeviceID, processRunning: await probe.child.isRunning,
                socketConnected: true, samples: samples, now: .now)
            try attempt.record(sample, candidateID: evidence.candidates.count == 1 ? evidence.candidates[0].id : nil)
            switch evaluateCorrelation(evidence) {
            case .passed: return evidence
            case let .failed(reason): throw ProbeError(reason: reason)
            case let .inconclusive(reason):
                if attempt.established && reason != .notAdvancing { throw ProbeError(reason: reason) }
                lastReason = reason
            }
        } catch let error as ProbeError where !attempt.established && [.notPaired, .ownershipChanged].contains(error.reason) {
            samples = []
            lastReason = error.reason
        }
        try await Task.sleep(for: .milliseconds(500))
    }
    throw ProbeError(reason: lastReason)
}

@main
enum ProbeMain {
    static func main() async {
        if CommandLine.arguments.dropFirst() == ["--help"] {
            print("soloist-feasibility --key-file PATH --client-id ID [--soloist PATH] [--report PATH]\nsoloist-feasibility --install-only [--report PATH]")
            return
        }
        let options: ProbeOptions
        do { options = try ProbeOptions.parse(Array(CommandLine.arguments.dropFirst())) }
        catch {
            probeMessage("Invalid flags. Run soloist-feasibility --help. Supply key-file paths, never keys.")
            exit(2)
        }
        let task = Task { await execute(options) }
        // Interruption must run asynchronous cleanup rather than orphaning an audio process.
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let signals = [SIGINT, SIGTERM].map { number in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { task.cancel() }
            source.resume()
            return source
        }
        let report = await task.value
        signals.forEach { $0.cancel() }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            if let destination = options.report {
                let fd = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
                guard fd >= 0 else { throw ProbeError(reason: .invalidInput) }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                try handle.write(contentsOf: data)
                try handle.close()
            }
            FileHandle.standardOutput.write(data + Data("\n".utf8))
        } catch {
            probeMessage("Could not write the sanitized report.")
            exit(2)
        }
        let passed = options.installOnly ? report.installation == .passed :
            report.correlation == .passed && report.restart == .passed && report.companion == .passed
        exit(passed ? 0 : 2)
    }

    private static func execute(_ options: ProbeOptions) async -> ProbeReport {
        var report = ProbeReport(correlation: .inconclusive(reason: .notRun))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bopify-soloist-\(UUID().uuidString)")
        var ownsDirectory = false
        var owned: OwnedSoloistProbe?
        let http = ProbeObservation()
        defer { http.session.invalidateAndCancel() }
        do {
            if let keyFile = options.keyFile { _ = try ProbeObservation.readKey(keyFile) }
            let executable: URL
            if let override = options.executable {
                try await ProbeObservation.validateArtifact(override)
                executable = override
            } else {
                probeMessage("Preparing the latest official Soloist build automatically.")
                let installation = try await SoloistInstaller().ensureInstalled { progress in
                    switch progress {
                    case let .downloading(received, total):
                        if let total { probeMessage("Downloading Soloist: \(received * 100 / max(1, total))%") }
                        else { probeMessage("Downloading Soloist: \(received) bytes") }
                    case .verifying: probeMessage("Verifying Spotify's signed player.")
                    case .installed: probeMessage("Soloist installed.")
                    case .updateReady: probeMessage("Soloist update staged.")
                    }
                }
                executable = installation.current.executableURL
                report.soloistVersion = installation.current.metadata.version
                report.installationError = installation.updateError
            }
            report.installation = .passed
            if options.installOnly { return report }
            guard let keyFile = options.keyFile, let clientID = options.clientID else { throw ProbeError(reason: .invalidInput) }
            let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("../../../..").standardizedFileURL
            probeMessage("Compiling the data-only companion before requesting credentials.")
            let companionExecutable = try await ProbeEvidence.prepareCompanion(repository: repository)
            let versionChild = try ProbeChild(executable: executable, arguments: ["--version"])
            let version = try await versionChild.wait(seconds: 30)
            guard version.status == 0 else { throw ProbeError(reason: .processFailed) }
            let versionText = String(decoding: version.output, as: UTF8.self)
            if let range = versionText.range(of: #"\b\d+\.\d+\.\d+(?:\.\d+)?\b"#, options: .regularExpression) {
                report.soloistVersion = String(versionText[range])
            }
            probeMessage("Sign in for a fresh, memory-only streaming grant.")
            let streaming = try await ProbeAuthorization.authorize(clientID: librespotClientID, scopes: ["streaming"],
                callbackPort: nil, callbackPath: "/login")
            probeMessage("Authorize playback observation/control with your developer client.")
            let web = try await ProbeAuthorization.authorize(clientID: clientID,
                scopes: ["user-read-playback-state", "user-modify-playback-state"],
                callbackPort: LibraryAuthorization.callbackPort, callbackPath: LibraryAuthorization.callbackPath)
            let streamingID = try await http.account(accessToken: streaming.accessToken)
            let webID = try await http.account(accessToken: web.accessToken)
            guard streamingID == webID else { throw ProbeError(reason: .accountMismatch) }
            let baseline = try await http.devices(accessToken: web.accessToken)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            ownsDirectory = true
            let name = "Bopify probe \(UUID().uuidString)"
            let probe = try await ProbeObservation.startSoloist(executable: executable,
                keyFile: keyFile, directory: root, deviceName: name)
            owned = probe
            probeMessage("Select \(name) in Spotify, start a track, and choose your listening volume there. Probe starts muted.")
            let evidence = try await collectCorrelation(probe: probe, http: http,
                streamingAccountID: streamingID, webAccountID: webID, webToken: web.accessToken,
                baseline: baseline, name: name)
            report.correlation = .passed
            report.samples += evidence.samples.count
            let id = evidence.candidates[0].id
            await probe.stop()
            owned = nil
            let restartBaseline = try await http.devices(accessToken: web.accessToken)
            let restarted = try await ProbeObservation.startSoloist(executable: executable,
                keyFile: keyFile, directory: root, deviceName: name)
            owned = restarted
            probeMessage("Probe restarted with the same session. Select it and start playback again if needed.")
            let revalidated = try await collectCorrelation(probe: restarted, http: http,
                streamingAccountID: streamingID, webAccountID: webID, webToken: web.accessToken,
                baseline: restartBaseline, name: name, knownDeviceID: id)
            report.restart = .passed
            report.samples += revalidated.samples.count
            guard let track = revalidated.samples.last?.soloist.itemURI else { throw ProbeError(reason: .invalidResponse) }
            probeMessage("Fetching lyrics, radio and artist data while observing Soloist for at least 30 seconds.")
            let observer = CompanionObservation(probe: restarted, http: http,
                webToken: web.accessToken, evidence: revalidated)
            let result = try await runObservedCompanion(operation: {
                try await ProbeEvidence.runCompanion(accessToken: streaming.accessToken,
                    trackURI: track, executable: companionExecutable)
            }, observe: { try await observer.check() })
            report.services = result
            report.companion = result.allAvailable ? .passed : .inconclusive(reason: .servicesUnavailable)
            probeMessage("State observations do not prove audible continuity. Record whether you heard uninterrupted audio separately.")
        } catch {
            if report.installation != .passed {
                report.installation = .inconclusive(reason: .installationFailed)
                report.installationError = error as? SoloistInstallationError
            }
            let failure = error as? ProbeError ?? ProbeError(reason: error is CancellationError ? .cancelled : .processFailed)
            if report.correlation != .passed { report.correlation = .inconclusive(reason: failure.reason) }
            else if report.restart != .passed { report.restart = .inconclusive(reason: failure.reason) }
            else { report.companion = .inconclusive(reason: failure.reason) }
            report.httpStatus = failure.status
            report.retryAfterSeconds = failure.retryAfter
        }
        await owned?.stop()
        if ownsDirectory { try? FileManager.default.removeItem(at: root) }
        return report
    }
}
