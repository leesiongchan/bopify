import Darwin
import Foundation
import BopifyDomain

/// Owns exactly the child it launches; stale runtime files never authorize adopting a process.
protocol SoloistProcessHandle: Sendable {
    var endpointURL: URL { get }
    var isRunning: Bool { get }
    func stop() async
}

final class SoloistProcess: SoloistProcessHandle, @unchecked Sendable {
    static var directory: URL { SoloistInstaller.defaultDirectory.appendingPathComponent("session", isDirectory: true) }
    let endpointURL: URL
    private let process: Process
    private let lockFD: Int32
    private let lock = NSLock()
    private var stopping: Task<Void, Never>?
    var isRunning: Bool { process.isRunning }

    private init(process: Process, lockFD: Int32, endpoint: URL) {
        self.process = process; self.lockFD = lockFD; endpointURL = endpoint
    }

    @concurrent static func start(executable: URL, key: String, name: String, volume: Double,
                                  directory root: URL = directory) async throws -> SoloistProcess {
        try Task.checkCancellation()
        for folder in [root, root.appendingPathComponent("data"), root.appendingPathComponent("cache")] {
            if mkdir(folder.path, 0o700) != 0 && errno != EEXIST { throw SoloistStartupError.storageUnavailable }
            var info = stat()
            guard lstat(folder.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else { throw SoloistStartupError.storageUnavailable }
        }
        let fd = open(root.appendingPathComponent("process.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw SoloistStartupError.storageUnavailable }
        var transferred = false
        defer { if !transferred { close(fd) } }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_mode & 0o777 == 0o600 else { throw SoloistStartupError.storageUnavailable }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw SoloistStartupError.processInUse }
        let data = root.appendingPathComponent("data")
        if let text = try? read(data.appendingPathComponent("soloist.pid"), limit: 32),
           let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0,
           kill(pid, 0) == 0 || errno == EPERM {
            try await SoloistOrphanRecovery.retire(pid: pid, root: root, executable: executable)
        }
        for name in ["ws.addr", "ws.port"] {
            let path = data.appendingPathComponent(name)
            if unlink(path.path) != 0 && errno != ENOENT { throw SoloistStartupError.storageUnavailable }
        }
        let child = Process()
        child.executableURL = executable
        child.arguments = ["--device-name", name, "--api-key", key, "--data-dir", data.path,
            "--cache-dir", root.appendingPathComponent("cache").path, "--cache-size", "100",
            "--initial-volume", String(Int((max(0, min(1, volume)) * 100).rounded())), "--ws", "127.0.0.1:0"]
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        child.standardInput = FileHandle.nullDevice
        do { try child.run() } catch {
            BopifyLog.playback.error("Soloist launch failed before process creation")
            throw SoloistStartupError.launchFailed
        }
        do {
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                try Task.checkCancellation()
                guard child.isRunning else {
                    child.waitUntilExit()
                    BopifyLog.playback.error("Soloist exited during startup status=\(child.terminationStatus, privacy: .public)")
                    throw SoloistStartupError.exited(child.terminationStatus)
                }
                if let endpoint = try? endpoint(in: data) {
                    transferred = true
                    return SoloistProcess(process: child, lockFD: fd, endpoint: endpoint)
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            BopifyLog.playback.error("Soloist startup timed out waiting for loopback endpoint")
            throw SoloistStartupError.endpointUnavailable
        } catch {
            await terminate(child)
            throw error
        }
    }

    func stop() async {
        let task = lock.withLock { () -> Task<Void, Never> in
            if let stopping { return stopping }
            let process = self.process, fd = lockFD
            let task = Task.detached { await Self.terminate(process); close(fd) }
            stopping = task
            return task
        }
        await task.value
    }

    private static func terminate(_ process: Process) async {
        await Task.detached {
            if process.isRunning {
                process.terminate()
                let deadline = Date().addingTimeInterval(2)
                while process.isRunning && Date() < deadline { usleep(20_000) }
                if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
            }
        }.value
    }

    static func endpoint(in directory: URL) throws -> URL {
        let address = try read(directory.appendingPathComponent("ws.addr"), limit: 128).trimmingCharacters(in: .whitespacesAndNewlines)
        let text = try read(directory.appendingPathComponent("ws.port"), limit: 8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard address == "127.0.0.1", let port = UInt16(text), port > 0,
              let url = URL(string: "ws://127.0.0.1:\(port)") else { throw SoloistPlaybackError.invalidState }
        return url
    }

    private static func read(_ url: URL, limit: Int) throws -> String {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw SoloistPlaybackError.invalidState }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_size <= limit, let data = try handle.read(upToCount: limit + 1), data.count <= limit,
              let text = String(data: data, encoding: .utf8) else { throw SoloistPlaybackError.invalidState }
        return text
    }

    public static func clearSession() throws { try clearSession(in: directory) }

    static func clearSession(in root: URL) throws {
        var info = stat()
        guard lstat(root.path, &info) == 0 else {
            if errno == ENOENT { return }; throw SoloistPlaybackError.startupFailed
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else {
            throw SoloistPlaybackError.startupFailed
        }
        let fd = open(root.appendingPathComponent("process.lock").path, O_RDWR | O_NOFOLLOW)
        guard fd >= 0 else { throw SoloistPlaybackError.startupFailed }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw SoloistPlaybackError.startupFailed }
        if let text = try? read(root.appendingPathComponent("data/soloist.pid"), limit: 32),
           let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0,
           kill(pid, 0) == 0 || errno == EPERM {
            throw SoloistPlaybackError.startupFailed
        }
        try FileManager.default.removeItem(at: root)
    }
}
