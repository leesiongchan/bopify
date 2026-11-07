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
