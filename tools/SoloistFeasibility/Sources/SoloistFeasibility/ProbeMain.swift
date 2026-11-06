import BopifyAuth
import Darwin
import Foundation

struct ProbeOptions: Sendable {
    let executable: URL
    let keyFile: URL
    let clientID: String
    let report: URL?

    static func parse(_ arguments: [String]) throws -> Self {
        let flags = ["--soloist", "--key-file", "--client-id", "--report"]
        var values: [String: String] = [:]
        guard arguments.count.isMultiple(of: 2) else { throw ProbeError(reason: .invalidInput) }
        for index in stride(from: 0, to: arguments.count, by: 2) {
            let flag = arguments[index], value = arguments[index + 1]
            guard flags.contains(flag), values[flag] == nil, !value.isEmpty else { throw ProbeError(reason: .invalidInput) }
            values[flag] = value
        }
        guard let executable = values["--soloist"], let key = values["--key-file"],
              let rawID = values["--client-id"], let id = LibraryAuthorization.normalized(rawID) else {
            throw ProbeError(reason: .invalidInput)
        }
        return Self(executable: URL(fileURLWithPath: executable).standardizedFileURL,
            keyFile: URL(fileURLWithPath: key).standardizedFileURL, clientID: id,
            report: values["--report"].map { URL(fileURLWithPath: $0).standardizedFileURL })
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
    var lastReason = ProbeReason.timeout
    while Date() < deadline {
        try Task.checkCancellation()
        do {
            async let local = probe.snapshot()
            async let remote = http.playback(accessToken: webToken)
            async let devices = http.devices(accessToken: webToken)
            let (snapshot, playback, discovered) = try await (local, remote, devices)
            guard let playback else {
                try await Task.sleep(for: .milliseconds(500))
                continue
            }
            if let previous = samples.last,
               previous.soloist.authGeneration != snapshot.authGeneration || previous.soloist.itemURI != snapshot.itemURI {
                samples = []
            }
            samples.append(ProbeSample(soloist: snapshot, web: playback))
            samples = Array(samples.suffix(2))
            let evidence = CorrelationEvidence(streamingAccountID: streamingAccountID, webAccountID: webAccountID,
                beforeDevices: baseline, afterDevices: discovered, expectedName: name, generation: probe.generation,
                knownDeviceID: knownDeviceID, processRunning: await probe.child.isRunning,
                socketConnected: true, samples: samples, now: .now)
            switch evaluateCorrelation(evidence) {
            case .passed: return evidence
            case let .failed(reason): throw ProbeError(reason: reason)
            case let .inconclusive(reason): lastReason = reason
            }
        } catch let error as ProbeError where error.reason == .notPaired {
            samples = []
            lastReason = .notPaired
        }
        try await Task.sleep(for: .milliseconds(500))
    }
    throw ProbeError(reason: lastReason)
}

@main
enum ProbeMain {
    static func main() async {
        if CommandLine.arguments.dropFirst() == ["--help"] {
            print("soloist-feasibility --soloist PATH --key-file PATH --client-id ID [--report PATH]")
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
        exit(report.correlation == .passed && report.restart == .passed && report.companion == .passed ? 0 : 2)
    }

    private static func execute(_ options: ProbeOptions) async -> ProbeReport {
        var report = ProbeReport(correlation: .inconclusive(reason: .notRun))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bopify-soloist-\(UUID().uuidString)")
        var ownsDirectory = false
        var owned: OwnedSoloistProbe?
        let http = ProbeObservation()
        defer { http.session.invalidateAndCancel() }
        do {
            try await ProbeObservation.validateArtifact(options.executable)
            _ = try ProbeObservation.readKey(options.keyFile)
            let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("../../../..").standardizedFileURL
            probeMessage("Compiling the data-only companion before requesting credentials.")
            let companionExecutable = try await ProbeEvidence.prepareCompanion(repository: repository)
            let versionChild = try ProbeChild(executable: options.executable, arguments: ["--version"])
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
            let web = try await ProbeAuthorization.authorize(clientID: options.clientID,
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
            let probe = try await ProbeObservation.startSoloist(executable: options.executable,
                keyFile: options.keyFile, directory: root, deviceName: name)
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
            let restarted = try await ProbeObservation.startSoloist(executable: options.executable,
                keyFile: options.keyFile, directory: root, deviceName: name)
            owned = restarted
            probeMessage("Probe restarted with the same session. Select it and start playback again if needed.")
            let revalidated = try await collectCorrelation(probe: restarted, http: http,
                streamingAccountID: streamingID, webAccountID: webID, webToken: web.accessToken,
                baseline: restartBaseline, name: name, knownDeviceID: id)
            report.restart = .passed
            report.samples += revalidated.samples.count
            guard let track = revalidated.samples.last?.soloist.itemURI else { throw ProbeError(reason: .invalidResponse) }
            probeMessage("Fetching lyrics, radio and artist data while observing Soloist for at least 30 seconds.")
            async let observed: Void = monitorCompanion(probe: restarted, http: http,
                webToken: web.accessToken, evidence: revalidated)
            async let services = ProbeEvidence.runCompanion(accessToken: streaming.accessToken,
                trackURI: track, executable: companionExecutable)
            let (result, _) = try await (services, observed)
            report.services = result
            report.companion = result.allAvailable ? .passed : .inconclusive(reason: .servicesUnavailable)
            probeMessage("State observations do not prove audible continuity. Record whether you heard uninterrupted audio separately.")
        } catch {
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
