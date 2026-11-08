import Foundation
import Testing
import BopifyAuth
@testable import SoloistFeasibility

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    return directory
}

@Test func CLIRejectsUnknownRepeatedAndMissingFlags() throws {
    let required = ["--soloist", "/tmp/soloist", "--key-file", "/tmp/key", "--client-id", String(repeating: "a", count: 32)]
    #expect(try ProbeOptions.parse(required).clientID == String(repeating: "a", count: 32))
    for arguments in [[], required + ["--api-key", "secret"], required + ["--soloist", "/tmp/other"],
                      Array(required.dropLast())] {
        #expect(throws: ProbeError.self) { try ProbeOptions.parse(arguments) }
    }
}

@Test func CLIInstallsAutomaticallyWithoutAnExecutablePath() throws {
    let options = try ProbeOptions.parse(["--key-file", "/tmp/key", "--client-id", String(repeating: "a", count: 32)])
    #expect(options.executable == nil)
    #expect(!options.installOnly)
    let install = try ProbeOptions.parse(["--install-only"])
    #expect(install.installOnly)
    #expect(install.keyFile == nil)
    #expect(throws: ProbeError.self) { try ProbeOptions.parse(["--install-only", "--soloist", "/tmp/binary"]) }
}

@Test func reportingMustNotOverwriteAnExistingFile() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appendingPathComponent("report.json")
    try Data("preserve-existing-work".utf8).write(to: destination)
    let executable = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../.build/debug/soloist-feasibility").standardizedFileURL
    let child = try ProbeChild(executable: executable, arguments: [
        "--soloist", root.appendingPathComponent("missing").path, "--key-file", "/unused",
        "--client-id", String(repeating: "a", count: 32), "--report", destination.path,
    ])
    _ = try await child.wait(seconds: 10)
    #expect(try String(contentsOf: destination, encoding: .utf8) == "preserve-existing-work")
}

@Test func endpointIsLimitedToOwnedLoopbackFiles() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("127.0.0.1".utf8).write(to: root.appendingPathComponent("ws.addr"))
    try Data("23456".utf8).write(to: root.appendingPathComponent("ws.port"))
    #expect(try ProbeObservation.endpoint(in: root).absoluteString == "ws://127.0.0.1:23456")
    for address in ["0.0.0.0", "example.com", "127.0.0.1/path", "::1"] {
        try Data(address.utf8).write(to: root.appendingPathComponent("ws.addr"))
        #expect(throws: ProbeError.self) { try ProbeObservation.endpoint(in: root) }
    }
    try FileManager.default.removeItem(at: root.appendingPathComponent("ws.addr"))
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("ws.addr"),
        withDestinationURL: root.appendingPathComponent("ws.port"))
    #expect(throws: ProbeError.self) { try ProbeObservation.endpoint(in: root) }
}

@Test func keyMustBePrivateRegularAndBounded() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let key = root.appendingPathComponent("key")
    try Data("sentinel-private-key\n".utf8).write(to: key)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path)
    #expect(try ProbeObservation.readKey(key) == "sentinel-private-key")
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: key.path)
    #expect(throws: ProbeError.self) { try ProbeObservation.readKey(key) }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path)
    try Data(repeating: 65, count: 4097).write(to: key)
    #expect(throws: ProbeError.self) { try ProbeObservation.readKey(key) }
    let link = root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: key)
    #expect(throws: ProbeError.self) { try ProbeObservation.readKey(link) }
}

@Test func restartingReusesItsExistingPrivateDirectories() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let key = root.appendingPathComponent("key")
    try Data("sentinel-key".utf8).write(to: key)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path)
    for _ in 0..<2 {
        do {
            _ = try await ProbeObservation.startSoloist(executable: URL(fileURLWithPath: "/usr/bin/false"),
                keyFile: key, directory: root, deviceName: "probe")
            Issue.record("A failing child unexpectedly became ready")
        } catch let error as ProbeError {
            #expect(error.reason == .processFailed)
        } catch {
            Issue.record("Directory preparation prevented restart")
        }
    }
}

@Test func trustRejectionPreventsExecutingTheSelectedArtifact() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let artifact = root.appendingPathComponent("soloist")
    try Data([0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0, 0, 1] + Array(repeating: 0, count: 24)).write(to: artifact)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: artifact.path)
    await #expect(throws: ProbeError.self) {
        try await ProbeObservation.validateArtifact(artifact, assess: { _ in false })
    }
}

@Test func malformedOversizeAndUnauthenticatedFramesDoNotBecomeSnapshots() throws {
    var state = SoloistWireState(generation: UUID())
    #expect(throws: ProbeError.self) { try state.apply(Data("not json".utf8), at: .now) }
    #expect(throws: ProbeError.self) { try state.apply(Data(repeating: 65, count: 1_048_577), at: .now) }
    let frame = Data(#"{"type":"playback_state","status":"playing","item":{"uri":"spotify:track:1111111111111111111111"},"is_active":true,"position":{"position_ms":10,"timestamp_ms":1000,"speed":1}}"#.utf8)
    #expect(throws: ProbeError.self) { try state.apply(frame, at: .now) }
}

@Test func authChangesInvalidateAnEarlierPlaybackSnapshot() throws {
    var state = SoloistWireState(generation: UUID())
    let date = Date(timeIntervalSince1970: 1)
    _ = try state.apply(Data(#"{"type":"auth_state","logged_in":true,"is_active":true,"device_name":"probe"}"#.utf8), at: date)
    let frame = Data(#"{"type":"playback_state","status":"playing","item":{"uri":"spotify:track:1111111111111111111111"},"is_active":true,"position":{"position_ms":1000,"timestamp_ms":1000,"speed":1}}"#.utf8)
    let snapshot = try state.apply(frame, at: date)
    let first = try #require(snapshot)
    _ = try state.apply(Data(#"{"type":"auth_state","logged_in":false,"is_active":false,"device_name":"probe"}"#.utf8), at: date)
    #expect(state.authGeneration > first.authGeneration)
    #expect(!state.paired)
}

@Test func queuedFramesDoNotBecomeFreshResponsesToLaterQueries() throws {
    var state = SoloistWireState(generation: UUID())
    let date = Date(timeIntervalSince1970: 100)
    _ = try state.apply(Data(#"{"type":"auth_state","logged_in":true,"is_active":true}"#.utf8), at: date)
    let frame = Data(#"{"type":"playback_state","status":"playing","item":{"uri":"spotify:track:1111111111111111111111"},"is_active":true,"position":{"position_ms":1000,"timestamp_ms":1000,"speed":1}}"#.utf8)
    _ = try state.apply(frame, at: date)
    #expect(state.snapshot(after: date.addingTimeInterval(1)) == nil)
    let stillFresh = try #require(state.snapshot(after: date.addingTimeInterval(-1)))
    #expect(stillFresh.positionMs == 100_000, "Old position anchors remain valid interpolation inputs")
    _ = try state.apply(Data(#"{"type":"device_changed","is_active":false,"device_name":"probe"}"#.utf8), at: date)
    #expect(state.latest?.active == false)
    _ = try state.apply(Data(#"{"type":"auth_state","logged_in":false,"is_active":false}"#.utf8), at: date)
    #expect(state.latest == nil)
}

private actor ObservationEvents {
    var started = false
    var ended = false
    var observedAfterEnd = false
    var ticks = 0
    func start() { started = true }
    func end() { ended = true }
    func tick() { ticks += 1; if ended { observedAfterEnd = true } }
}

@Test func observationContinuesUntilASlowCompanionEnds() async throws {
    let events = ObservationEvents()
    let result = try await runObservedCompanion(minimumDuration: .milliseconds(20), interval: .milliseconds(2), operation: {
        await events.start()
        try await Task.sleep(for: .milliseconds(80))
        await events.end()
        return 42
    }, observe: { await events.tick() })
    #expect(result == 42)
    #expect(await events.observedAfterEnd)
    #expect(await events.ticks > 2)
}

@Test func observationFailureCancelsAndJoinsTheAuthenticatedOperationPromptly() async throws {
    let events = ObservationEvents()
    let start = ContinuousClock.now
    await #expect(throws: ProbeError.self) {
        try await runObservedCompanion(minimumDuration: .seconds(30), interval: .milliseconds(2), operation: {
            await events.start()
            do { try await Task.sleep(for: .seconds(10)) }
            catch { await events.end(); throw error }
            await events.end()
            return 42
        }, observe: {
            while await !events.started { await Task.yield() }
            throw ProbeError(reason: .ownershipChanged)
        })
    }
    #expect(start.duration(to: .now) < .seconds(1))
    #expect(await events.ended)
}

@Test func cleanupStopsOnlyItsOwnedProcess() async throws {
    let unrelated = try ProbeChild(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"])
    let owned = try ProbeChild(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"])
    await owned.stop()
    #expect(await !owned.isRunning)
    #expect(await unrelated.isRunning)
    await unrelated.stop()
}

@Test func cancellationStopsAChildRatherThanLeavingItRunning() async throws {
    let child = try ProbeChild(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"])
    let task = Task { try await child.wait(seconds: 30) }
    task.cancel()
    await #expect(throws: (any Error).self) { try await task.value }
    #expect(await !child.isRunning)
}

@Test func failedChildDoesNotLeakItsOutputInErrors() async throws {
    let child = try ProbeChild(executable: URL(fileURLWithPath: "/usr/bin/false"), arguments: [])
    let result = try await child.wait(seconds: 2)
    #expect(result.status != 0)
}

@Test func aFailedCompanionDoesNotAcceptOrExposeThePrivateInput() async {
    await #expect(throws: ProbeError.self) {
        try await ProbeEvidence.runCompanion(accessToken: "sentinel-private-token",
            trackURI: "spotify:track:1111111111111111111111", executable: URL(fileURLWithPath: "/usr/bin/false"))
    }
}

@Test func cancelledAuthorizationDoesNotOpenABrowser() async {
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await ProbeAuthorization.authorize(clientID: "unused", scopes: [],
            callbackPort: nil, callbackPath: "/login")
    }
    task.cancel()
    await #expect(throws: (any Error).self) { try await task.value }
}

private final class ResponseProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let status: Int
        let body: String
        switch request.value(forHTTPHeaderField: "Authorization") {
        case "Bearer denied": status = 403; body = #"{"error":"sentinel-secret-error"}"#
        case "Bearer limited": status = 429; body = ""
        case "Bearer legacy": status = 200; body = #"{"id":"legacy-username"}"#
        default: status = 204; body = ""
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
            httpVersion: nil, headerFields: ["Retry-After": "5"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test func HTTPFailuresAndLegacyProfileNeverProvideAccountLinkage() async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ResponseProtocol.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    let observation = ProbeObservation(session: session)
    for (token, reason) in [("denied", ProbeReason.httpStatus), ("limited", .rateLimited), ("legacy", .missingAccountID)] {
        do {
            _ = try await observation.account(accessToken: token)
            Issue.record("Unusable profile was accepted")
        } catch let error as ProbeError {
            #expect(error.reason == reason)
            #expect(!String(describing: error).contains("sentinel-secret-error"))
            if token == "limited" { #expect(error.retryAfter == 5) }
        }
    }
    #expect(try await observation.playback(accessToken: "none") == nil)
}
