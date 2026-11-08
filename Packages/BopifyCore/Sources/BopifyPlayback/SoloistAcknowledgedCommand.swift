import Foundation

/// One batch owns this socket: Soloist errors have no request ID, so sharing it with
/// polling or unrelated controls would make a rejection impossible to correlate.
struct SoloistAcknowledgedCommand: Sendable {
    let transport: any SoloistTransport

    func send(_ command: String, uri: String) async throws {
        let data = try JSONSerialization.data(withJSONObject: ["type": "command", "command": command, "uri": uri])
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await transport.send(data)
                for try await frame in transport.messages {
                    try Task.checkCancellation()
                    guard let value = try JSONSerialization.jsonObject(with: frame.data) as? [String: Any] else {
                        throw SoloistPlaybackError.invalidState
                    }
                    if value["type"] as? String == "error" { throw SoloistPlaybackError.unavailable }
                    if value["type"] as? String == "command_result", value["command"] as? String == command { return }
                }
                throw SoloistPlaybackError.unavailable
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw SoloistPlaybackError.unavailable
            }
            do {
                _ = try await group.next()
                group.cancelAll()
            } catch {
                group.cancelAll()
                await transport.close()
                throw error
            }
        }
    }
}
