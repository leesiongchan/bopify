import Darwin
import Foundation
import Testing
@testable import BopifyPlayback

/// Opt-in integration against Spotify's signed CLI; never uses the user's key or session.
@Test(.enabled(if: ProcessInfo.processInfo.environment["BOPIFY_SOLOIST_TEST_EXECUTABLE"] != nil))
func soloistSignedDaemonRecoversOrphanAndRestarts() async throws {
    let source = try #require(ProcessInfo.processInfo.environment["BOPIFY_SOLOIST_TEST_EXECUTABLE"])
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    let build = root.appendingPathComponent("builds/fixture")
    let session = root.appendingPathComponent("session")
    try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    for folder in [session, session.appendingPathComponent("data"), session.appendingPathComponent("cache")] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = build.appendingPathComponent("soloist")
    try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: executable)
    try SoloistCodeSignature.validate(executable)
    let shell = Process()
    shell.executableURL = URL(fileURLWithPath: "/bin/sh")
    shell.arguments = ["-c", "\"$@\" >/dev/null 2>&1 </dev/null &", "fixture", executable.path,
        "--device-name", "Bopify isolated fixture", "--api-key", "synthetic-invalid-key",
        "--data-dir", session.appendingPathComponent("data").path,
        "--cache-dir", session.appendingPathComponent("cache").path, "--cache-size", "100",
        "--initial-volume", "0", "--ws", "127.0.0.1:0"]
    shell.standardOutput = FileHandle.nullDevice; shell.standardError = FileHandle.nullDevice
    try shell.run(); shell.waitUntilExit()
    let deadline = Date().addingTimeInterval(15)
    while (try? SoloistProcess.endpoint(in: session.appendingPathComponent("data"))) == nil, Date() < deadline {
        try await Task.sleep(for: .milliseconds(50))
    }
    _ = try SoloistProcess.endpoint(in: session.appendingPathComponent("data"))
    let pidURL = session.appendingPathComponent("data/soloist.pid")
    let oldPID = try #require(Int32(String(contentsOf: pidURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
    var path = [CChar](repeating: 0, count: 4096)
    #expect(proc_pidpath(oldPID, &path, UInt32(path.count)) > 0)
    let runningPath = String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    #expect(URL(fileURLWithPath: runningPath).resolvingSymlinksInPath().path == executable.resolvingSymlinksInPath().path)
    defer {
        var current = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(oldPID, &current, UInt32(current.count)) > 0, current == path { _ = kill(oldPID, SIGTERM) }
    }
    await #expect(throws: SoloistStartupError.processInUse) {
        try await SoloistOrphanRecovery.retire(pid: oldPID, root: root.appendingPathComponent("another-session"), executable: executable)
    }
    #expect(kill(oldPID, 0) == 0, "A signed orphan for another session must remain untouched")
    for _ in 0..<2 {
        let process = try await SoloistProcess.start(executable: executable, key: "synthetic-invalid-key",
            name: "Bopify isolated fixture", volume: 0, directory: session)
        #expect(process.isRunning)
        #expect(process.endpointURL.host == "127.0.0.1")
        let diagnosticDeadline = Date().addingTimeInterval(10)
        while (process.pairingPort == nil || !process.diagnosticEvents.contains(.mdnsReady)), Date() < diagnosticDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(process.diagnosticFailure == nil)
        #expect(process.diagnosticEvents.contains(.mdnsReady))
        #expect(process.pairingPort.map { $0 > 0 } == true)
        await process.stop()
        #expect(!process.isRunning)
    }
    try await SoloistRuntimeCheck.verify(executable: executable)
}
