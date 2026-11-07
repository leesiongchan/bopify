import Darwin
import Foundation
import Testing
import BopifyAuth

@MainActor @Suite("Desktop data migration", .serialized)
struct DesktopDataMigrationTests {
    private func fixture() throws -> (URL, URL, URL, UserDefaults) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-migration-\(UUID())")
        let old = root.appendingPathComponent("legacy"), new = root.appendingPathComponent("desktop")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let defaults = UserDefaults(suiteName: root.appendingPathComponent("preferences").path)!
        return (root, old, new, defaults)
    }
    private func write(_ value: Any, to url: URL, plist: Bool = false) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try plist ? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0) : JSONSerialization.data(withJSONObject: value)
        try data.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    @Test func preservesSettingsCleanupAndPairingWithoutImportingExecutablesOrResurrectingPreferences() throws {
        let (root, old, new, defaults) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = old.appendingPathComponent("Library/Preferences/com.leesiongchan.bopify.plist")
        try write(["library.clientID": String(repeating: "a", count: 32), "soloist.enabled": true,
                   "player.volume": 0.7, "record.hasScrubbed": true, "soloist.installationBookmark": Data([1])], to: preferences, plist: true)
        let support = old.appendingPathComponent("Library/Application Support/com.leesiongchan.bopify")
        try write(["version": 1, "pending": ["soloist"]], to: support.appendingPathComponent("logout-intent.json"))
        try write(["fixture": true], to: support.appendingPathComponent("Soloist/session/data/pairing.json"))
        try write(["untrusted": true], to: support.appendingPathComponent("Soloist/current.json"))
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try LogoutIntentStore(url: new.appendingPathComponent("logout-intent.json")).begin([.playback])
        defaults.set(0.2, forKey: "player.volume")
        let migration = DesktopDataMigration(legacyContainer: old, destination: new, defaults: defaults, otherInstanceIsRunning: { false })
        try migration.run()
        #expect(defaults.double(forKey: "player.volume") == 0.2)
        #expect(defaults.bool(forKey: "record.hasScrubbed"))
        #expect(defaults.string(forKey: "library.clientID") == String(repeating: "a", count: 32))
        #expect(defaults.object(forKey: "soloist.installationBookmark") == nil)
        #expect(FileManager.default.fileExists(atPath: new.appendingPathComponent("Soloist/session/data/pairing.json").path))
        #expect(!FileManager.default.fileExists(atPath: support.appendingPathComponent("Soloist/session").path))
        #expect(!FileManager.default.fileExists(atPath: new.appendingPathComponent("Soloist/current.json").path))
        let intent = LogoutIntentStore(url: new.appendingPathComponent("logout-intent.json"))
        #expect(try intent.isPending(.soloist) && intent.isPending(.playback))
        defaults.set(false, forKey: "soloist.enabled")
        try intent.complete(.soloist); try intent.complete(.playback)
        try migration.run()
        #expect(!defaults.bool(forKey: "soloist.enabled"))
        #expect(try !LogoutIntentStore(url: new.appendingPathComponent("logout-intent.json")).hasPendingCleanup())
    }
    @Test(arguments: ["live", "locked", "conflict"])
    func refusesActiveOrConflictingSessionsBeforeImportingPreferences(_ condition: String) throws {
        let (root, old, new, defaults) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = old.appendingPathComponent("Library/Application Support/com.leesiongchan.bopify/Soloist/session")
        try write(["fixture": true], to: session.appendingPathComponent("data/pairing.json"))
        let fd = open(session.appendingPathComponent("process.lock").path, O_CREAT | O_RDWR, 0o600)
        #expect(fd >= 0); defer { close(fd) }
        if condition == "locked" { #expect(flock(fd, LOCK_EX | LOCK_NB) == 0) }
        if condition == "live" { try Data(String(getpid()).utf8).write(to: session.appendingPathComponent("data/soloist.pid")) }
        if condition == "conflict" { try FileManager.default.createDirectory(at: new.appendingPathComponent("Soloist/session"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        #expect(throws: (any Error).self) { try DesktopDataMigration(legacyContainer: old, destination: new, defaults: defaults, otherInstanceIsRunning: { false }).run() }
        #expect(FileManager.default.fileExists(atPath: session.appendingPathComponent("data/pairing.json").path))
        #expect(defaults.object(forKey: "library.clientID") == nil)
    }
    @Test func anotherAppInstanceBlocksAuthenticationEvenWithoutASoloistSessionOrAfterMigration() throws {
        let (root, old, new, defaults) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let blocked = DesktopDataMigration(legacyContainer: old, destination: new, defaults: defaults, otherInstanceIsRunning: { true })
        #expect(throws: (any Error).self) { try blocked.run() }
        try DesktopDataMigration(legacyContainer: old, destination: new, defaults: defaults, otherInstanceIsRunning: { false }).run()
        #expect(throws: (any Error).self) { try blocked.run() }
    }
    @Test(arguments: ["oversized", "symlink", "directory"])
    func destinationCleanupIsValidatedBeforeAnyMigration(_ invalid: String) throws {
        let (root, old, new, defaults) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let intent = new.appendingPathComponent("logout-intent.json")
        if invalid == "symlink" {
            let outside = root.appendingPathComponent("other.json")
            try write(["version": 1, "pending": []], to: outside)
            try FileManager.default.createSymbolicLink(at: intent, withDestinationURL: outside)
        } else if invalid == "directory" {
            try FileManager.default.createDirectory(at: intent, withIntermediateDirectories: false)
        } else {
            var data = try JSONSerialization.data(withJSONObject: ["version": 1, "pending": []])
            data.append(Data(repeating: 32, count: 65_537))
            try data.write(to: intent)
        }
        #expect(throws: (any Error).self) {
            try DesktopDataMigration(legacyContainer: old, destination: new, defaults: defaults, otherInstanceIsRunning: { false }).run()
        }
        #expect(!FileManager.default.fileExists(atPath: new.appendingPathComponent("desktop-migration-v1").path))
    }

    @Test func corruptCleanupOrSymlinkCannotBeTreatedAsNoLegacyData() throws {
        let (root, old, new, defaults) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let intent = old.appendingPathComponent("Library/Application Support/com.leesiongchan.bopify/logout-intent.json")
        try write(["version": 99, "pending": []], to: intent)
        #expect(throws: (any Error).self) { try DesktopDataMigration(legacyContainer: old, destination: new, defaults: defaults, otherInstanceIsRunning: { false }).run() }
        try FileManager.default.removeItem(at: intent)
        try FileManager.default.createSymbolicLink(at: intent, withDestinationURL: root.appendingPathComponent("missing"))
        #expect(throws: (any Error).self) { try DesktopDataMigration(legacyContainer: old, destination: new, defaults: defaults, otherInstanceIsRunning: { false }).run() }
    }
}
