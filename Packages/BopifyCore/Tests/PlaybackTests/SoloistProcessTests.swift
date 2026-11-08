import Darwin
import Foundation
import Testing
@testable import BopifyPlayback

@Test func soloistOrphanRequiresExactSessionArguments() {
    let data = URL(fileURLWithPath: "/private/session/data")
    let cache = URL(fileURLWithPath: "/private/session/cache")
    let arguments = ["soloist", "--api-key", "synthetic-secret", "--data-dir", data.path,
                     "--cache-dir", cache.path]
    #expect(SoloistOrphanRecovery.matchesSession(arguments, data: data, cache: cache))
    #expect(!SoloistOrphanRecovery.matchesSession(arguments + ["--data-dir", "/other"], data: data, cache: cache))
    #expect(!SoloistOrphanRecovery.matchesSession(["soloist", "--data-dir", data.path], data: data, cache: cache))
    #expect(!SoloistOrphanRecovery.matchesSession(["soloist", "--data-dir", "/other", "--cache-dir", cache.path], data: data, cache: cache))
}

@Test func soloistNeverRetiresAnUnrelatedLivePID() async throws {
    let root = try processTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    await #expect(throws: SoloistStartupError.processInUse) {
        try await SoloistOrphanRecovery.retire(pid: getpid(), root: root, executable: URL(fileURLWithPath: "/bin/sleep"))
    }
    #expect(kill(getpid(), 0) == 0)
}

@Test func soloistLaunchFailureIsSpecificAndReleasesSessionLock() async throws {
    let root = try processTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    for _ in 0..<2 {
        await #expect(throws: SoloistStartupError.launchFailed) {
            _ = try await SoloistProcess.start(executable: URL(fileURLWithPath: "/no-such-soloist"),
                key: "synthetic-secret", name: "Fixture", volume: 0, directory: root)
        }
    }
}

@Test func soloistEarlyExitReportsExitStatusAndCanRetry() async throws {
    let root = try processTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let script = root.appendingPathComponent("fixture")
    try Data("#!/bin/sh\nexit 10\n".utf8).write(to: script)
    #expect(chmod(script.path, 0o700) == 0)
    for _ in 0..<2 {
        await #expect(throws: SoloistStartupError.exited(10)) {
            _ = try await SoloistProcess.start(executable: script, key: "synthetic-secret",
                name: "Fixture", volume: 0, directory: root)
        }
    }
}

private func processTestDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return root
}

@Test func soloistVerboseOutputDrainsBothChannelsBeforeEndpointReadiness() async throws {
    let root = try processTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let script = try diagnosticProcessFixture(in: root)
    let process = try await SoloistProcess.start(executable: script, key: "synthetic-secret", name: "Fixture", volume: 0, directory: root)
    let deadline = Date().addingTimeInterval(2)
    while process.diagnosticFailure == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(process.isRunning)
    #expect(process.pairingPort == 43210)
    #expect(process.diagnosticFailure == .invalidKey)
    #expect(process.diagnosticEvents == [.mdnsReady, .pairingServerReady(43210), .keyRejected])
    async let first: Void = process.stop()
    async let second: Void = process.stop()
    _ = await (first, second)
    #expect(!process.isRunning)
}

@Test func soloistCancellationDuringOutputDrainReleasesTheSessionForRetry() async throws {
    let root = try processTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let script = try diagnosticProcessFixture(in: root, endpoint: false)
    let launch = Task { try await SoloistProcess.start(executable: script, key: "synthetic-secret", name: "Fixture", volume: 0, directory: root) }
    let started = root.appendingPathComponent("started")
    let deadline = Date().addingTimeInterval(5)
    while !FileManager.default.fileExists(atPath: started.path), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    let didStart = FileManager.default.fileExists(atPath: started.path)
    launch.cancel()
    await #expect(throws: CancellationError.self) { _ = try await launch.value }
    try #require(didStart)
    _ = try diagnosticProcessFixture(in: root)
    let retry = try await SoloistProcess.start(executable: script, key: "synthetic-secret", name: "Fixture", volume: 0, directory: root)
    #expect(retry.isRunning)
    await retry.stop()
}

private func diagnosticProcessFixture(in root: URL, endpoint: Bool = true) throws -> URL {
    let script = root.appendingPathComponent("diagnostic-fixture")
    let contents = """
    #!/bin/sh
    verbose=false
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --data-dir) data="$2"; shift 2 ;;
            --verbose) verbose=true; shift ;;
            *) shift ;;
        esac
    done
    [ "$verbose" = true ] || exit 12
    printf 'started' > "$data/../started"
    i=0
    while [ "$i" -lt 10000 ]; do
        printf 'unrecognized private vendor payload that must never be retained or logged\\n' >&2
        i=$((i + 1))
    done
    printf 'mdns created successfully\\n'
    printf 'Started ZeroConf service on port 43210 path /zc\\n' >&2
    printf 'login failed while API key is configured: synthetic-secret\\n' >&2
    \(endpoint ? "printf '127.0.0.1' > \"$data/ws.addr\"\nprintf '12345' > \"$data/ws.port\"" : "")
    exec /bin/sleep 30
    """
    try Data(contents.utf8).write(to: script)
    #expect(chmod(script.path, 0o700) == 0)
    return script
}
