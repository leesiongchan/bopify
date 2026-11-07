import Foundation
import BopifyPlayback

/// Opt-in signed-app acceptance check. Runs before migration, UI setup, or any credential access.
enum SoloistInstallationCheck {
    static let argument = "--verify-soloist-installation"

    static func run() async -> Int32 {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bopify-install-check-\(UUID())")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let installer = SoloistInstaller(directory: root.appendingPathComponent("Soloist"))
            let fresh = try await installer.ensureInstalled(forceCheck: true)
            let cached = try await installer.ensureInstalled()
            guard fresh.current.digest == cached.current.digest,
                  fresh.current.executableURL == cached.current.executableURL else { throw SoloistInstallationError.invalidInstallation }
            try FileManager.default.removeItem(at: root)
            report(["status": "passed", "version": fresh.current.metadata.version,
                    "publisherAndVersionValidated": true, "cacheReused": true, "temporaryFilesRemoved": true])
            return 0
        } catch {
            try? FileManager.default.removeItem(at: root)
            report(["status": "failed", "reason": (error as? SoloistInstallationError)?.rawValue ?? "installationCheckFailed"])
            return 1
        }
    }

    private static func report(_ value: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: .sortedKeys) {
            FileHandle.standardOutput.write(data + Data([10]))
        }
    }
}
