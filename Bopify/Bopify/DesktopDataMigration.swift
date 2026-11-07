import Darwin
import AppKit
import Foundation
import os
import BopifyAuth
import BopifyDomain

/// Import the previous sandbox's data once, before any Keychain-backed service is constructed.
@MainActor struct DesktopDataMigration {
    enum Failure: Error { case unavailable, invalidData, activeSession, conflictingSession }
    private let legacyContainer: URL
    private let destination: URL
    private let defaults: UserDefaults
    private let otherInstanceIsRunning: () -> Bool
    private let fm = FileManager.default
    private nonisolated struct CleanupRecord: Codable {
        let version: Int
        let pending: [CredentialNamespace]
    }

    init(legacyContainer: URL? = nil, destination: URL? = nil, defaults: UserDefaults = .standard,
         otherInstanceIsRunning: @escaping () -> Bool = {
             NSRunningApplication.runningApplications(withBundleIdentifier: "com.leesiongchan.bopify")
                 .contains { !$0.isTerminated && $0.processIdentifier != getpid() }
         }) {
        self.legacyContainer = legacyContainer ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.leesiongchan.bopify/Data", isDirectory: true)
        self.destination = destination ?? LogoutIntentStore.defaultURL.deletingLastPathComponent()
        self.defaults = defaults
        self.otherInstanceIsRunning = otherInstanceIsRunning
    }

    func run() throws {
        guard !otherInstanceIsRunning() else { throw Failure.activeSession }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = try openLock(destination.appendingPathComponent("desktop-migration.lock"))
        defer { close(lock) }
        let marker = destination.appendingPathComponent("desktop-migration-v1")
        if let data = try read(marker, limit: 1) {
            guard data == Data([1]) else { throw Failure.invalidData }
            return
        }
        if try exists(legacyContainer, directory: true) {
            let support = legacyContainer.appendingPathComponent("Library/Application Support/com.leesiongchan.bopify")
            let preferencesURL = legacyContainer.appendingPathComponent("Library/Preferences/com.leesiongchan.bopify.plist")
            let preferences: [String: Any]
            if let data = try read(preferencesURL, limit: 1_048_576) {
                guard let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                    throw Failure.invalidData
                }
                preferences = values
            } else { preferences = [:] }
            let oldIntentURL = support.appendingPathComponent("logout-intent.json")
            let pending = try cleanupPending(at: oldIntentURL)
            // Validate cleanup before moving data; a corrupt intent must not restore old grants.
            let currentIntentURL = destination.appendingPathComponent("logout-intent.json")
            let currentPending = try cleanupPending(at: currentIntentURL)
            try moveSession(from: support.appendingPathComponent("Soloist/session"))
            if !pending.isEmpty {
                let record = CleanupRecord(version: 1, pending: pending.union(currentPending).sorted { $0.rawValue < $1.rawValue })
                try JSONEncoder().encode(record).write(to: currentIntentURL, options: .atomic)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: currentIntentURL.path)
            }
            for (key, value) in preferences where allowedPreference(key) && defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
            // Commit preferences before the durable marker prevents another import.
            guard defaults.synchronize() else { throw Failure.unavailable }
        }
        defaults.removeObject(forKey: "soloist.installationBookmark")
        try Data([1]).write(to: marker, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
        BopifyLog.auth.info("desktop data migration complete")
    }

    private func allowedPreference(_ key: String) -> Bool {
        key == "record.hasScrubbed" || (key != "soloist.installationBookmark"
            && ["library.", "soloist.", "player.", "KeyboardShortcuts_"].contains { key.hasPrefix($0) })
    }

    private func cleanupPending(at url: URL) throws -> Set<CredentialNamespace> {
        guard let data = try read(url, limit: 65_536) else { return [] }
        let record = try JSONDecoder().decode(CleanupRecord.self, from: data)
        guard record.version == 1 else { throw Failure.invalidData }
        return Set(record.pending)
    }

    private func moveSession(from source: URL) throws {
        guard try exists(source, directory: true) else { return }
        let lock = try openLock(source.appendingPathComponent("process.lock"))
        defer { close(lock) }
        if let data = try read(source.appendingPathComponent("data/soloist.pid"), limit: 32) {
            guard let text = String(data: data, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else {
                throw Failure.invalidData
            }
            if kill(pid, 0) == 0 || errno == EPERM { throw Failure.activeSession }
        }
        let target = destination.appendingPathComponent("Soloist/session")
        guard try !exists(target, directory: true) else { throw Failure.conflictingSession }
        // No credential duplication: moving the directory leaves nothing for the old build to restore.
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard renamex_np(source.path, target.path, UInt32(RENAME_EXCL)) == 0 else { throw Failure.unavailable }
    }

    private func exists(_ url: URL, directory: Bool) throws -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return false }; throw Failure.unavailable
        }
        guard info.st_uid == getuid(), info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG) else { throw Failure.invalidData }
        return true
    }

    private func openLock(_ url: URL) throws -> Int32 {
        let fd = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Failure.unavailable }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o777 == 0o600, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd); throw Failure.activeSession
        }
        return fd
    }

    private func read(_ url: URL, limit: Int) throws -> Data? {
        guard try exists(url, directory: false) else { return nil }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw Failure.unavailable }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_size <= limit, let data = try file.read(upToCount: limit + 1), data.count <= limit else { throw Failure.invalidData }
        return data
    }
}
