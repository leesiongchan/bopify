import Darwin
import Foundation
import Security
import BopifyDomain

public enum SoloistStartupError: Error, Equatable, Sendable {
    case storageUnavailable, processInUse, launchFailed, endpointUnavailable, exited(Int32)
}

/// Called only while holding the private session's exclusive application lock.
enum SoloistOrphanRecovery {
    private struct Identity: Equatable {
        let seconds: UInt64
        let microseconds: UInt64
    }

    static func retire(pid: pid_t, root: URL, executable: URL) async throws {
        if kill(pid, 0) != 0, errno == ESRCH { return }
        let data = root.appendingPathComponent("data"), cache = root.appendingPathComponent("cache")
        guard let identity = identity(pid), let path = executablePath(pid) else { throw refused("processIdentity") }
        let builds = executable.deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath()
        let running = URL(fileURLWithPath: path)
        // A stale PID alone never authorizes a signal. Require our immutable install location,
        // Spotify's running-code identity, and both exact private session arguments as well.
        guard builds.lastPathComponent == "builds", running.lastPathComponent == "soloist",
              running.deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath().path == builds.path
        else { throw refused("installLocation") }
        guard (try? SoloistCodeSignature.validate(running)) != nil else { throw refused("installedPublisher") }
        guard trustedRunningCode(pid) else { throw refused("runningPublisher") }
        guard let arguments = arguments(pid) else { throw refused("argumentRead") }
        guard matchesSession(arguments, data: data, cache: cache) else { throw refused("sessionArguments") }
        guard self.identity(pid) == identity else { throw refused("identityChanged") }
        guard kill(pid, SIGTERM) == 0 || errno == ESRCH else { throw SoloistStartupError.processInUse }
        BopifyLog.playback.notice("Soloist orphan recovery requested; verified session and publisher")
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if self.identity(pid) != identity {
                BopifyLog.playback.info("Soloist orphan recovery completed")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        // Never escalate to SIGKILL for a process we did not launch in this app lifetime.
        throw SoloistStartupError.processInUse
    }

    private static func refused(_ reason: String) -> SoloistStartupError {
        BopifyLog.playback.error("Soloist orphan recovery refused reason=\(reason, privacy: .public)")
        return .processInUse
    }

    private static func identity(_ pid: pid_t) -> Identity? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) == MemoryLayout.size(ofValue: info),
              info.pbi_uid == getuid(), info.pbi_ppid == 1, info.pbi_status != SZOMB else { return nil }
        return Identity(seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
    }

    private static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func trustedRunningCode(_ pid: pid_t) -> Bool {
        var code: SecCode?, requirement: SecRequirement?
        return SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &code) == errSecSuccess
            && SecRequirementCreateWithString(SoloistCodeSignature.publisherRequirement as CFString, [], &requirement) == errSecSuccess
            && code != nil && requirement != nil
            && SecCodeCheckValidity(code!, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess
    }

    /// The kernel argument buffer can contain the API key; it is never persisted or logged.
    private static func arguments(_ pid: pid_t) -> [String]? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size >= 4, size <= 2_097_152 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard (1...128).contains(argc) else { return nil }
        var index = 4
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var result: [String] = []
        for _ in 0..<argc {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            guard index < size, let value = String(bytes: buffer[start..<index], encoding: .utf8) else { return nil }
            result.append(value); index += 1
        }
        return result
    }

    static func matchesSession(_ arguments: [String], data: URL, cache: URL) -> Bool {
        func exact(_ option: String, _ short: String, _ path: String) -> Bool {
            let indices = arguments.indices.filter { arguments[$0] == option || arguments[$0] == short }
            guard indices.count == 1, let index = indices.first, index + 1 < arguments.count else { return false }
            return arguments[index + 1] == path
        }
        return exact("--data-dir", "-D", data.path) && exact("--cache-dir", "-C", cache.path)
    }
}
