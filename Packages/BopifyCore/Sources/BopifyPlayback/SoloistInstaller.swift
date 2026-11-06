import Darwin
import Foundation

public struct SoloistInstalledBuild: Sendable {
    public let metadata: SoloistBuildMetadata
    public let digest: String
    public let executableURL: URL
}

public struct SoloistInstallation: Sendable {
    public let current: SoloistInstalledBuild
    public let pending: SoloistInstalledBuild?
    public let updateError: SoloistInstallationError?
}

private struct SoloistRecord: Codable {
    let metadata: SoloistBuildMetadata
    let digest: String
    let directory: String
}

private struct SoloistManifest: Codable {
    var schemaVersion = 1
    var current: SoloistRecord?
    var pending: SoloistRecord?
    var previous: SoloistRecord?
    var checkedAt: Date?
    var lastError: SoloistInstallationError?
}

/// Manages official Spotify binaries only. It never stops or restarts an audio process.
public actor SoloistInstaller {
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.leesiongchan.bopify/Soloist", isDirectory: true)
    }

    private let directory: URL
    private let now: @Sendable () -> Date
    private let download: @Sendable (URL, @escaping @Sendable (SoloistInstallProgress) -> Void) async throws -> Void
    private let validate: @Sendable (URL, Date) async throws -> SoloistBuildMetadata
    private var flight: Task<SoloistInstallation, any Error>?
    private var flightPolicy: (canActivate: Bool, forceCheck: Bool)?

    public init(directory: URL = SoloistInstaller.defaultDirectory) {
        self.directory = directory.standardizedFileURL
        now = Date.init
        download = SoloistDownload.fetch
        validate = SoloistCodeSignature.build
    }

    init(directory: URL, now: @escaping @Sendable () -> Date,
        download: @escaping @Sendable (URL, @escaping @Sendable (SoloistInstallProgress) -> Void) async throws -> Void,
        validate: @escaping @Sendable (URL, Date) async throws -> SoloistBuildMetadata) {
        self.directory = directory.standardizedFileURL
        self.now = now
        self.download = download
        self.validate = validate
    }

    /// Pass false while a child still owns playback, including an active paused queue.
    /// A pending replacement is activated only when the caller can safely launch a new child.
    /// Concurrent callers must agree on activation/check policy or retry after installationBusy.
    /// If only a staged build is usable and activation is blocked, throws activationRequired.
    public func ensureInstalled(canActivateUpdate: Bool = true, forceCheck: Bool = false,
        progress: @escaping @Sendable (SoloistInstallProgress) -> Void = { _ in }) async throws -> SoloistInstallation {
        try Task.checkCancellation()
        if let flight {
            guard flightPolicy?.canActivate == canActivateUpdate, flightPolicy?.forceCheck == forceCheck else {
                throw SoloistInstallationError.installationBusy
            }
            let result = try await flight.value
            try Task.checkCancellation()
            return result
        }
        let task = Task { try await perform(canActivateUpdate: canActivateUpdate, forceCheck: forceCheck, progress: progress) }
        flight = task
        flightPolicy = (canActivateUpdate, forceCheck)
        defer { flight = nil; flightPolicy = nil }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func perform(canActivateUpdate: Bool, forceCheck: Bool,
        progress: @escaping @Sendable (SoloistInstallProgress) -> Void) async throws -> SoloistInstallation {
        try Task.checkCancellation()
        try prepareDirectory()
        let lockFD = open(directory.appendingPathComponent("install.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard lockFD >= 0 else { throw SoloistInstallationError.invalidInstallation }
        defer { _ = flock(lockFD, LOCK_UN); close(lockFD) }
        var info = stat()
        guard fstat(lockFD, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_mode & 0o777 == 0o600 else { throw SoloistInstallationError.invalidInstallation }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw SoloistInstallationError.installationBusy }
        var manifest = try loadManifest()
        let date = now()
        var current = await usable(manifest.current, at: date)
        var pending = await usable(manifest.pending, at: date)
        if let pending, canActivateUpdate {
            manifest.previous = manifest.current
            manifest.current = manifest.pending
            manifest.pending = nil
            current = pending
            try save(manifest)
        }
        if manifest.pending == nil { pending = nil }
        if current == nil, pending != nil, !canActivateUpdate, !forceCheck,
           let checked = manifest.checkedAt, (0..<86_400).contains(date.timeIntervalSince(checked)) {
            throw SoloistInstallationError.activationRequired
        }
        if let current, !forceCheck, let checked = manifest.checkedAt,
           (0..<86_400).contains(date.timeIntervalSince(checked)) {
            return SoloistInstallation(current: current, pending: pending, updateError: manifest.lastError)
        }
        let stage = directory.appendingPathComponent("staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: stage) }
        do {
            let archive = stage.appendingPathComponent("soloist.tar.gz")
            try await download(archive, progress)
            try Task.checkCancellation()
            let contents = stage.appendingPathComponent("contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try SoloistArchive.extract(archive, to: contents)
            progress(.verifying)
            let executable = contents.appendingPathComponent("soloist")
            let metadata = try await validate(executable, now())
            guard metadata.isUsable(at: now()) else { throw SoloistInstallationError.expiredBuild }
            let digest = try soloistDigest(executable)
            if let current, metadata.builtAt <= current.metadata.builtAt {
                guard metadata.builtAt == current.metadata.builtAt && digest == current.digest else {
                    throw SoloistInstallationError.invalidVersion
                }
            } else {
                let name = "\(digest)-\(UUID().uuidString)"
                let destination = directory.appendingPathComponent("builds").appendingPathComponent(name)
                try Task.checkCancellation()
                try FileManager.default.moveItem(at: contents, to: destination)
                let record = SoloistRecord(metadata: metadata, digest: digest, directory: name)
                let installed = SoloistInstalledBuild(metadata: metadata, digest: digest,
                    executableURL: destination.appendingPathComponent("soloist"))
                if canActivateUpdate {
                    manifest.previous = manifest.current
                    manifest.current = record
                    manifest.pending = nil
                    current = installed
                    pending = nil
                    progress(.installed)
                } else {
                    manifest.pending = record
                    pending = installed
                    progress(.updateReady)
                }
            }
            manifest.checkedAt = now()
            manifest.lastError = nil
            try save(manifest)
        } catch {
            if error is CancellationError { throw error }
            let failure = error as? SoloistInstallationError ?? .invalidInstallation
            guard current != nil else { throw failure }
            manifest.checkedAt = now()
            manifest.lastError = failure
            try save(manifest)
        }
        guard let current else {
            throw pending == nil ? SoloistInstallationError.invalidInstallation : .activationRequired
        }
        return SoloistInstallation(current: current, pending: pending, updateError: manifest.lastError)
    }

    private func usable(_ record: SoloistRecord?, at date: Date) async -> SoloistInstalledBuild? {
        guard let record, record.digest.count == 64,
              record.digest.allSatisfy({ $0.isASCII && ($0.isHexDigit && !$0.isUppercase) }),
              record.directory.hasPrefix(record.digest + "-"),
              UUID(uuidString: String(record.directory.dropFirst(65))) != nil,
              record.metadata.isUsable(at: date) else { return nil }
        let folder = directory.appendingPathComponent("builds").appendingPathComponent(record.directory)
        guard (try? requirePrivateDirectory(folder)) != nil else { return nil }
        let executable = folder.appendingPathComponent("soloist")
        guard let digest = try? soloistDigest(executable), digest == record.digest,
              let metadata = try? await validate(executable, date), metadata == record.metadata else { return nil }
        return SoloistInstalledBuild(metadata: metadata, digest: digest, executableURL: executable)
    }

    private func prepareDirectory() throws {
        let marker = directory.appendingPathComponent("owner")
        var info = stat()
        if lstat(directory.path, &info) != 0 {
            guard errno == ENOENT else { throw SoloistInstallationError.invalidInstallation }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try writePrivate(Data("com.leesiongchan.bopify.soloist.v1".utf8), to: marker)
        }
        try requirePrivateDirectory(directory)
        guard try readPrivate(marker, limit: 128) == Data("com.leesiongchan.bopify.soloist.v1".utf8) else {
            throw SoloistInstallationError.invalidInstallation
        }
        let builds = directory.appendingPathComponent("builds")
        if mkdir(builds.path, 0o700) != 0 && errno != EEXIST { throw SoloistInstallationError.invalidInstallation }
        try requirePrivateDirectory(builds)
    }

    private func loadManifest() throws -> SoloistManifest {
        let path = directory.appendingPathComponent("current.json")
        var info = stat()
        if lstat(path.path, &info) != 0 {
            guard errno == ENOENT else { throw SoloistInstallationError.invalidInstallation }
            return SoloistManifest()
        }
        guard let manifest = try? JSONDecoder().decode(SoloistManifest.self, from: readPrivate(path, limit: 16_384)),
              manifest.schemaVersion == 1 else { throw SoloistInstallationError.invalidInstallation }
        return manifest
    }

    private func save(_ manifest: SoloistManifest) throws {
        let temp = directory.appendingPathComponent("manifest-\(UUID().uuidString)")
        try writePrivate(JSONEncoder().encode(manifest), to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        guard rename(temp.path, directory.appendingPathComponent("current.json").path) == 0 else {
            throw SoloistInstallationError.invalidInstallation
        }
    }
}

private func requirePrivateDirectory(_ url: URL) throws {
    var info = stat()
    guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
          info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else { throw SoloistInstallationError.invalidInstallation }
}

private func readPrivate(_ url: URL, limit: Int) throws -> Data {
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard fd >= 0 else { throw SoloistInstallationError.invalidInstallation }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
          info.st_mode & 0o777 == 0o600, info.st_size <= limit,
          let data = try handle.read(upToCount: limit + 1), data.count <= limit else {
        throw SoloistInstallationError.invalidInstallation
    }
    return data
}

private func writePrivate(_ data: Data, to url: URL) throws {
    let fd = open(url.path, O_WRONLY | O_CREAT | O_NOFOLLOW | O_EXCL, 0o600)
    guard fd >= 0 else { throw SoloistInstallationError.invalidInstallation }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    try handle.write(contentsOf: data)
    guard fsync(fd) == 0 else { throw SoloistInstallationError.invalidInstallation }
    try handle.close()
}
