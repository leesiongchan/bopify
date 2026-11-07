import Foundation

/// Credential-free acceptance check for the installed daemon and its actual loopback protocol.
public enum SoloistRuntimeCheck {
    public static func verify(executable: URL) async throws {
        try SoloistCodeSignature.validate(executable)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bopify-runtime-check-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        for _ in 0..<2 {
            let child = try await SoloistProcess.start(executable: executable, key: "synthetic-invalid-key",
                name: "Bopify installation check", volume: 0, directory: root)
            let socket = SoloistSocket(endpoint: child.endpointURL)
            do {
                try await socket.send(Data(#"{"type":"command","command":"get_state"}"#.utf8))
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for try await frame in socket.messages {
                            if let json = try? JSONSerialization.jsonObject(with: frame.data) as? [String: Any],
                               let type = json["type"] as? String, ["auth_state", "playback_state"].contains(type) { return }
                        }
                        throw SoloistStartupError.endpointUnavailable
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(10))
                        throw SoloistStartupError.endpointUnavailable
                    }
                    do { _ = try await group.next(); group.cancelAll() }
                    catch { group.cancelAll(); await socket.close(); throw error }
                }
                await socket.close()
                await child.stop()
            } catch {
                await socket.close()
                await child.stop()
                throw error
            }
        }
    }
}
