import Foundation
import os
import BopifyDomain

public enum CredentialNamespace: String, Codable, Sendable, CaseIterable {
    case playback, library
}

/// Non-secret intent survives process restarts even when Keychain deletion fails.
/// One shared instance serializes updates from the two independent auth actors.
public final class LogoutIntentStore: @unchecked Sendable {
    private struct Record: Codable {
        let version: Int
        let pending: [CredentialNamespace]
    }
    private let lock = NSLock()
    private let url: URL
    private var state: Result<Set<CredentialNamespace>, Error>

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.leesiongchan.bopify", isDirectory: true)
            .appendingPathComponent("logout-intent.json")
    }

    public init(url: URL = LogoutIntentStore.defaultURL) {
        self.url = url
        state = Result {
            let data: Data
            do { data = try Data(contentsOf: url) }
            catch CocoaError.fileReadNoSuchFile { return [] }
            let record = try JSONDecoder().decode(Record.self, from: data)
            guard record.version == 1 else { throw PlayerError.credentialCleanupRequired }
            return Set(record.pending)
        }
    }

    public func hasPendingCleanup() throws -> Bool {
        try lock.withLock { try !state.get().isEmpty }
    }

    public func isPending(_ namespace: CredentialNamespace) throws -> Bool {
        try lock.withLock { try state.get().contains(namespace) }
    }

    public func begin(_ namespaces: Set<CredentialNamespace>) throws {
        try lock.withLock {
            // Explicit cleanup can repair corrupt metadata only by removing both grants.
            let pending = ((try? state.get()) ?? Set(CredentialNamespace.allCases)).union(namespaces)
            state = .success(pending)
            try write(pending)
        }
        BopifyLog.auth.info("credential cleanup intent recorded")
    }

    public func complete(_ namespace: CredentialNamespace) throws {
        try lock.withLock {
            var pending = try state.get()
            guard pending.remove(namespace) != nil else { return }
            // Keep the pending bit in memory until the replacement is acknowledged.
            try write(pending)
            state = .success(pending)
        }
        BopifyLog.auth.debug("credential cleanup completion recorded")
    }

    private func write(_ pending: Set<CredentialNamespace>) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let record = Record(version: 1, pending: pending.sorted { $0.rawValue < $1.rawValue })
        try JSONEncoder().encode(record).write(to: url, options: .atomic)
    }
}
