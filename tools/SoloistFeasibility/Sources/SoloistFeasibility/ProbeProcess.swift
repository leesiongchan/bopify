import Darwin
import Foundation

func withProbeTimeout<T: Sendable>(seconds: Double,
    operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw ProbeError(reason: .timeout)
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw ProbeError(reason: .cancelled) }
        return result
    }
}

struct ProbeProcessResult: Sendable {
    let status: Int32
    let output: Data
}

/// Captures bounded stdout privately; dependency stderr never reaches the terminal.
actor ProbeChild {
    private let process: Process
    private let output: Task<Data?, Never>
    var isRunning: Bool { process.isRunning }

    init(executable: URL, arguments: [String], directory: URL? = nil,
         environment: [String: String]? = nil, input: Data? = nil) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment
        let stdout = Pipe()
        let stdin = input.map { _ in Pipe() }
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = stdin ?? FileHandle.nullDevice as Any
        do { try process.run() }
        catch { throw ProbeError(reason: .processFailed) }
        try? stdout.fileHandleForWriting.close()
        self.process = process
        output = Task.detached {
            defer { try? stdout.fileHandleForReading.close() }
            var collected = Data()
            var overflow = false
            do {
                while let chunk = try stdout.fileHandleForReading.read(upToCount: 4096), !chunk.isEmpty {
                    if collected.count + chunk.count <= 1_048_576 { collected.append(chunk) }
                    else { overflow = true }
                }
                return overflow ? nil : collected
            } catch { return nil }
        }
        if let stdin, let input {
            do { try stdin.fileHandleForWriting.write(contentsOf: input) }
            catch {
                try? stdin.fileHandleForWriting.close()
                process.terminate()
                process.waitUntilExit()
                throw ProbeError(reason: .processFailed)
            }
            try? stdin.fileHandleForWriting.close()
        }
    }

    func wait(seconds: Double) async throws -> ProbeProcessResult {
        let deadline = Date().addingTimeInterval(seconds)
        do {
            while process.isRunning {
                try Task.checkCancellation()
                guard Date() < deadline else { throw ProbeError(reason: .timeout) }
                try await Task.sleep(for: .milliseconds(20))
            }
            try Task.checkCancellation()
            guard let data = await output.value else { throw ProbeError(reason: .invalidResponse) }
            return ProbeProcessResult(status: process.terminationStatus, output: data)
        } catch {
            await stop()
            throw error
        }
    }

    func stop() async {
        let process = self.process
        // Cleanup must finish even if the calling task has already been canceled.
        await Task.detached {
            if process.isRunning {
                process.terminate()
                let deadline = Date().addingTimeInterval(2)
                while process.isRunning && Date() < deadline { usleep(20_000) }
                if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
            }
        }.value
        _ = await output.value
    }
}

func readOwnedFile(_ url: URL, limit: Int, mode: mode_t? = nil, prefix: Int? = nil) throws -> Data {
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard fd >= 0 else { throw ProbeError(reason: .invalidInput) }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
          info.st_size > 0, info.st_size <= limit,
          mode == nil || info.st_mode & 0o777 == mode else { throw ProbeError(reason: .invalidInput) }
    guard let data = try? handle.read(upToCount: prefix ?? (limit + 1)), data.count <= limit else {
        throw ProbeError(reason: .invalidInput)
    }
    return data
}
