import Foundation
import Darwin
import Testing
@testable import BopifyPlayback

private let installNow = Date(timeIntervalSince1970: 1_800_000_000)

@Test func SoloistVersionRejectsEmptyComponents() {
    for version in ["1..3", "1.3.", ".1.3"] {
        #expect(throws: SoloistInstallationError.self) {
            try SoloistBuildMetadata.parse("soloist \(version) build 1800000000", at: installNow)
        }
    }
}

@Test func SoloistBuildExpiryUsesBuildTimeRatherThanInstallationTime() throws {
    let fresh = try SoloistBuildMetadata.parse("soloist 1.3.10.50 build 1800000000 (date) (macos/aarch64)", at: installNow)
    #expect(fresh.isUsable(at: installNow.addingTimeInterval(89 * 86_400)))
    #expect(!fresh.isUsable(at: installNow.addingTimeInterval(90 * 86_400)))
    for output in ["other 1.3 build 1800000000", "soloist 1.3 build invalid",
                   "soloist 1.3 build 1700000000", "soloist 1.3 build 1900000000"] {
        #expect(throws: SoloistInstallationError.self) { try SoloistBuildMetadata.parse(output, at: installNow) }
    }
}

private struct ArchiveEntry {
    let name: String
    var content = Data("fixture".utf8)
    var type: UInt8 = 48
    var link = ""
    var declaredSize: Int? = nil
}

private func tarFixture(_ entries: [ArchiveEntry]) -> Data {
    var archive = Data()
    for entry in entries {
        var header = [UInt8](repeating: 0, count: 512)
        func field(_ text: String, at offset: Int, length: Int) {
            for (index, byte) in text.utf8.prefix(length).enumerated() { header[offset + index] = byte }
        }
        field(entry.name, at: 0, length: 100)
        field("0000700", at: 100, length: 8)
        field("0000000", at: 108, length: 8)
        field("0000000", at: 116, length: 8)
        field(String(format: "%011o", entry.declaredSize ?? entry.content.count), at: 124, length: 12)
        field("00000000000", at: 136, length: 12)
        field("        ", at: 148, length: 8)
        header[156] = entry.type
        field(entry.link, at: 157, length: 100)
        field("ustar", at: 257, length: 6)
        field("00", at: 263, length: 2)
        field(String(format: "%06o", header.reduce(0) { $0 + Int($1) }), at: 148, length: 6)
        header[154] = 0
        header[155] = 32
        archive.append(contentsOf: header)
        archive.append(entry.content)
        archive.append(Data(repeating: 0, count: (512 - entry.content.count % 512) % 512))
    }
    archive.append(Data(repeating: 0, count: 1024))
    return archive
}

private func withArchive(_ entries: [ArchiveEntry], action: (URL, URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = root.appendingPathComponent("archive.tar")
    let destination = root.appendingPathComponent("output")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    try tarFixture(entries).write(to: archive)
    try action(archive, destination)
}

@Test func SoloistArchivePreservesExecutableAndNoticesWithoutExtractingOtherFiles() throws {
    try withArchive([ArchiveEntry(name: "soloist"), ArchiveEntry(name: "THIRD_PARTY_LICENSES.txt"),
                     ArchiveEntry(name: "CHANGELOG.md"), ArchiveEntry(name: "unrelated.txt")]) { archive, destination in
        try SoloistArchive.extract(archive, to: destination)
        let names = try FileManager.default.contentsOfDirectory(atPath: destination.path)
        #expect(Set(names) == ["soloist", "THIRD_PARTY_LICENSES.txt", "CHANGELOG.md"])
        #expect(try Data(contentsOf: destination.appendingPathComponent("soloist")) == Data("fixture".utf8))
    }
}

@Test func SoloistArchiveRejectsTraversalLinksDuplicateNamesAndOversizedEntries() throws {
    let unsafe: [[ArchiveEntry]] = [
        [ArchiveEntry(name: "../soloist")], [ArchiveEntry(name: "/soloist")],
        [ArchiveEntry(name: "folder\\soloist")],
        [ArchiveEntry(name: "soloist", type: 50, link: "/tmp/elsewhere")],
        [ArchiveEntry(name: "soloist", type: 49, link: "other")],
        [ArchiveEntry(name: "soloist"), ArchiveEntry(name: "nested/soloist")],
        [ArchiveEntry(name: "soloist", declaredSize: 160 * 1024 * 1024 + 1)],
        [ArchiveEntry(name: "CHANGELOG.md")],
    ]
    for entries in unsafe {
        try withArchive(entries) { archive, destination in
            #expect(throws: SoloistInstallationError.self) { try SoloistArchive.extract(archive, to: destination) }
        }
    }
}

private final class InstallClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = installNow
    var now: Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
}

private actor InstallSource {
    var version = "1.3.0"
    var built = installNow.addingTimeInterval(-86_400)
    var requests = 0
    var fail = false
    var hold = false
    var suspended = false
    var release: CheckedContinuation<Void, Never>?
    func holdDownloads() { hold = true }
    func resumeDownloads() { hold = false; release?.resume(); release = nil }
    func publish(at date: Date) { version = "1.4.0"; built = date }
    func failDownloads() { fail = true }
    func download(to destination: URL, progress: @Sendable (SoloistInstallProgress) -> Void) async throws {
        requests += 1
        if hold {
            await withCheckedContinuation { release = $0; suspended = true }
            suspended = false
        }
        try await Task.sleep(for: .milliseconds(20))
        if fail { throw SoloistInstallationError.downloadFailed }
        let body = Data("\(version)|\(Int(built.timeIntervalSince1970))".utf8)
        try tarFixture([ArchiveEntry(name: "soloist", content: body), ArchiveEntry(name: "THIRD_PARTY_LICENSES.txt")])
            .write(to: destination)
    }
}

@Test func SoloistInstallerRejectsConflictingInFlightPolicies() async throws {
    let (root, installer, _, source) = try installFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    await source.holdDownloads()
    let owner = Task { try await installer.ensureInstalled() }
    while await !source.suspended { await Task.yield() }
    let unblock = Task {
        try await Task.sleep(for: .milliseconds(100))
        await source.resumeDownloads()
    }
    defer { unblock.cancel() }
    await #expect(throws: SoloistInstallationError.installationBusy) {
        try await installer.ensureInstalled(canActivateUpdate: false)
    }
    await #expect(throws: SoloistInstallationError.installationBusy) {
        try await installer.ensureInstalled(forceCheck: true)
    }
    await source.resumeDownloads()
    _ = try await owner.value
}

@Test(arguments: [false, true])
func SoloistInstallerNeverActivatesDuringOwnedPlaybackWhenTheCurrentBuildBecomesUnusable(tampered: Bool) async throws {
    let (root, installer, clock, source) = try installFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try await installer.ensureInstalled()
    if tampered { try Data("tampered".utf8).write(to: first.current.executableURL) }
    clock.advance((tampered ? 1 : 91) * 86_400 + 1)
    await source.publish(at: clock.now)
    await #expect(throws: SoloistInstallationError.self) {
        try await installer.ensureInstalled(canActivateUpdate: false)
    }
    let manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf:
        root.appendingPathComponent("managed/current.json"))) as? [String: Any])
    let current = try #require(manifest["current"] as? [String: Any])
    #expect(current["directory"] as? String == first.current.executableURL.deletingLastPathComponent().lastPathComponent)
    #expect(manifest["pending"] != nil)
    let activated = try await installer.ensureInstalled()
    #expect(activated.current.metadata.version == "1.4.0")
    #expect(activated.pending == nil)
    #expect(await source.requests == 2)
}

@Test(arguments: [false, true])
func SoloistArchivePreservesQuarantine(embedded: Bool) throws {
    let value = "0081;00000000;Bopify;00000000-0000-0000-0000-000000000001"
    let quarantine = Data(value.utf8)
    var entries: [ArchiveEntry] = []
    for name in ["soloist", "THIRD_PARTY_LICENSES.txt"] {
        if embedded {
            let record = " SCHILY.xattr.com.apple.quarantine=\(value)\n"
            var length = record.utf8.count + 1
            while String(length).count + record.utf8.count != length { length = String(length).count + record.utf8.count }
            entries.append(ArchiveEntry(name: "PaxHeader", content: Data("\(length)\(record)".utf8), type: 120))
        }
        entries.append(ArchiveEntry(name: name))
    }
    try withArchive(entries) { archive, destination in
        if !embedded {
            let status = quarantine.withUnsafeBytes { setxattr(archive.path, "com.apple.quarantine", $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }
            #expect(status == 0)
        }
        try SoloistArchive.extract(archive, to: destination)
        for name in ["soloist", "THIRD_PARTY_LICENSES.txt"] {
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = getxattr(destination.appendingPathComponent(name).path, "com.apple.quarantine", &buffer, buffer.count, 0, XATTR_NOFOLLOW)
            #expect(count == quarantine.count)
            if count >= 0 { #expect(Data(buffer.prefix(count)) == quarantine) }
        }
    }
}

private func installFixture() throws -> (URL, SoloistInstaller, InstallClock, InstallSource) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let clock = InstallClock(), source = InstallSource()
    let installer = SoloistInstaller(directory: directory.appendingPathComponent("managed"), now: { clock.now },
        download: { path, progress in try await source.download(to: path, progress: progress) },
        validate: { path, at in
            let parts = try String(contentsOf: path, encoding: .utf8).split(separator: "|")
            guard parts.count == 2 else { throw SoloistInstallationError.invalidExecutable }
            return try SoloistBuildMetadata.parse("soloist \(parts[0]) build \(parts[1])", at: at)
        })
    return (directory, installer, clock, source)
}

@Test func SoloistInstallerDownloadsOnceAndReusesAValidatedDailyCache() async throws {
    let (root, installer, _, source) = try installFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try await installer.ensureInstalled()
    let cached = try await installer.ensureInstalled()
    #expect(first.current.executableURL == cached.current.executableURL)
    #expect(first.current.metadata.version == "1.3.0")
    #expect(await source.requests == 1)
    #expect(FileManager.default.fileExists(atPath: first.current.executableURL.deletingLastPathComponent()
        .appendingPathComponent("THIRD_PARTY_LICENSES.txt").path))
}

@Test func SoloistInstallerStagesUpdatesUntilTheCallerCanActivateThem() async throws {
    let (root, installer, clock, source) = try installFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try await installer.ensureInstalled()
    clock.advance(86_401)
    await source.publish(at: clock.now)
    let running = try await installer.ensureInstalled(canActivateUpdate: false)
    #expect(running.current.executableURL == first.current.executableURL)
    #expect(running.pending?.metadata.version == "1.4.0")
    let activated = try await installer.ensureInstalled()
    #expect(activated.current.metadata.version == "1.4.0")
    #expect(activated.pending == nil)
    #expect(FileManager.default.fileExists(atPath: first.current.executableURL.path))
    #expect(await source.requests == 2)
}

@Test func SoloistInstallerRetainsAWorkingBuildOnUpdateFailureAndRepairsTampering() async throws {
    let (root, installer, clock, source) = try installFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try await installer.ensureInstalled()
    clock.advance(86_401)
    await source.failDownloads()
    let fallback = try await installer.ensureInstalled()
    #expect(fallback.current.executableURL == first.current.executableURL)
    #expect(fallback.updateError == .downloadFailed)
    try Data("tampered".utf8).write(to: first.current.executableURL)
    await #expect(throws: SoloistInstallationError.self) { try await installer.ensureInstalled() }
}

@Test func SoloistInstallerRenewsAnExpiredBuildRatherThanUsingTheDailyCache() async throws {
    let (root, installer, clock, source) = try installFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try await installer.ensureInstalled()
    clock.advance(91 * 86_400)
    await source.publish(at: clock.now)
    let renewed = try await installer.ensureInstalled()
    #expect(renewed.current.metadata.version == "1.4.0")
    #expect(await source.requests == 2)
}

@Test func SoloistInstallerCoalescesConcurrentCallsAndCleansUpCancellation() async throws {
    let (root, installer, _, source) = try installFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    async let first = installer.ensureInstalled()
    async let second = installer.ensureInstalled()
    _ = try await (first, second)
    #expect(await source.requests == 1)
    let canceled = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await installer.ensureInstalled(forceCheck: true)
    }
    await #expect(throws: (any Error).self) { try await canceled.value }
    let names = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("managed").path)
    #expect(!names.contains(where: { $0.hasPrefix("staging-") }))
}

@Test func SoloistIntegrityChecksDoNotFollowAnExecutableSymlink() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let unrelated = root.appendingPathComponent("unrelated")
    try Data("sentinel-private-content".utf8).write(to: unrelated)
    let executable = root.appendingPathComponent("soloist")
    try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: unrelated)
    #expect(throws: SoloistInstallationError.self) { try soloistDigest(executable) }
}
