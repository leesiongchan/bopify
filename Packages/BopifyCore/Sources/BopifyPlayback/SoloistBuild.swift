import CryptoKit
import CSoloistArchive
import Darwin
import Foundation
import Security

public enum SoloistInstallationError: String, Error, Codable, Sendable {
    case invalidArchive, invalidExecutable, invalidVersion, expiredBuild, signatureInvalid
    case downloadFailed, downloadTooLarge, invalidInstallation, installationBusy, activationRequired, cancelled
}

public struct SoloistBuildMetadata: Codable, Equatable, Sendable {
    public let version: String
    public let builtAt: Date
    public var expiresAt: Date { builtAt.addingTimeInterval(90 * 86_400) }

    public func isUsable(at date: Date) -> Bool {
        builtAt <= date.addingTimeInterval(86_400) && date < expiresAt
    }

    static func parse(_ output: String, at date: Date) throws -> Self {
        let words = output.split(whereSeparator: \.isWhitespace)
        let components = words.count > 1 ? words[1].split(separator: ".", omittingEmptySubsequences: false) : []
        guard words.first == "soloist", words.count >= 4,
              let build = words.firstIndex(of: "build"), build + 1 < words.count,
              let timestamp = UInt64(words[build + 1]), timestamp > 0,
              (2...4).contains(components.count), words[1].count <= 64,
              components.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }) else {
            throw SoloistInstallationError.invalidVersion
        }
        let result = Self(version: String(words[1]), builtAt: Date(timeIntervalSince1970: Double(timestamp)))
        guard result.isUsable(at: date) else { throw SoloistInstallationError.expiredBuild }
        return result
    }
}

enum SoloistArchive {
    static func extract(_ archive: URL, to directory: URL) throws {
        guard bopify_soloist_extract(archive.path, directory.path) == 0 else {
            throw SoloistInstallationError.invalidArchive
        }
    }
}

public enum SoloistCodeSignature {
    /// Verify the standalone CLI's publisher; app-bundle Gatekeeper assessment does not apply here.
    public static func validate(_ executable: URL) throws {
        let fd = open(executable.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw SoloistInstallationError.invalidExecutable }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= 160 * 1024 * 1024,
              let header = try? file.read(upToCount: 8), header.elementsEqual([0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0, 0, 1]) else {
            throw SoloistInstallationError.invalidExecutable
        }
        var code: SecStaticCode?, requirement: SecRequirement?
        let rule = #"anchor apple generic and identifier "com.spotify.soloist" and certificate leaf[subject.OU] = "2FNC3A47ZF""#
        guard SecStaticCodeCreateWithPath(executable as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else {
            throw SoloistInstallationError.signatureInvalid
        }
    }

    static func build(_ executable: URL, at date: Date) async throws -> SoloistBuildMetadata {
        try validate(executable)
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { throw SoloistInstallationError.invalidExecutable }
        try? pipe.fileHandleForWriting.close()
        let output = Task.detached { () -> Data? in
            defer { try? pipe.fileHandleForReading.close() }
            var data = Data()
            do {
                while let chunk = try pipe.fileHandleForReading.read(upToCount: 4096), !chunk.isEmpty {
                    guard data.count + chunk.count <= 65_536 else {
                        if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
                        return nil
                    }
                    data.append(chunk)
                }
                return data
            } catch { return nil }
        }
        do {
            let deadline = Date().addingTimeInterval(30)
            while process.isRunning {
                try Task.checkCancellation()
                guard Date() < deadline else { throw SoloistInstallationError.invalidVersion }
                try await Task.sleep(for: .milliseconds(20))
            }
            guard process.terminationStatus == 0, let data = await output.value,
                  let text = String(data: data, encoding: .utf8) else { throw SoloistInstallationError.invalidVersion }
            return try SoloistBuildMetadata.parse(text, at: date)
        } catch {
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            await Task.detached { process.waitUntilExit() }.value
            _ = await output.value
            throw error
        }
    }
}

func soloistDigest(_ executable: URL) throws -> String {
    let fd = open(executable.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard fd >= 0 else { throw SoloistInstallationError.invalidExecutable }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    var info = stat()
    let limit = 160 * 1024 * 1024
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
          info.st_uid == getuid(), info.st_size > 0, info.st_size <= limit,
          let data = try handle.read(upToCount: limit + 1), data.count == info.st_size else {
        throw SoloistInstallationError.invalidExecutable
    }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
