import Darwin
import Foundation

struct ProbeObservation: Sendable {
    let session: URLSession
    init(session: URLSession = probeSession()) { self.session = session }

    private func get(_ path: String, token: String) async throws -> Data? {
        try Task.checkCancellation()
        var request = URLRequest(url: URL(string: "https://api.spotify.com" + path)!,
            cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw ProbeError(reason: .observationLost) }
        guard let http = response as? HTTPURLResponse else { throw ProbeError(reason: .invalidResponse) }
        if http.statusCode == 204 { return nil }
        if http.statusCode == 429 {
            let header = http.value(forHTTPHeaderField: "Retry-After") ?? ""
            let seconds = Double(header).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            throw ProbeError(reason: .rateLimited, status: 429, retryAfter: seconds)
        }
        guard http.statusCode == 200 else { throw ProbeError(reason: .httpStatus, status: http.statusCode) }
        guard data.count <= 1_048_576 else { throw ProbeError(reason: .invalidResponse) }
        return data
    }

    func account(accessToken: String) async throws -> String {
        guard let data = try await get("/v1/me", token: accessToken),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["account_id"] as? String, !id.isEmpty else {
            throw ProbeError(reason: .missingAccountID)
        }
        return id
    }

    func devices(accessToken: String) async throws -> Set<ProbeDevice> {
        struct Response: Decodable { let devices: [ProbeDevice] }
        guard let data = try await get("/v1/me/player/devices", token: accessToken),
              let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw ProbeError(reason: .invalidResponse)
        }
        return Set(response.devices)
    }

    func playback(accessToken: String) async throws -> ProbePlayback? {
        let requestedAt = Date()
        guard let data = try await get("/v1/me/player", token: accessToken) else { return nil }
        struct Entity: Decodable { let uri: String? }
        struct Device: Decodable { let id: String? }
        struct Response: Decodable {
            let device: Device?
            let item: Entity?
            let context: Entity?
            let is_playing: Bool
            let progress_ms: Double?
        }
        guard let value = try? JSONDecoder().decode(Response.self, from: data),
              let position = value.progress_ms, position.isFinite, position >= 0 else {
            throw ProbeError(reason: .invalidResponse)
        }
        return ProbePlayback(deviceID: value.device?.id, itemURI: value.item?.uri,
            contextURI: value.context?.uri, isPlaying: value.is_playing,
            positionMs: position, observedAt: requestedAt)
    }

    static func endpoint(in directory: URL) throws -> URL {
        let address = String(decoding: try readOwnedFile(directory.appendingPathComponent("ws.addr"), limit: 128), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let portText = String(decoding: try readOwnedFile(directory.appendingPathComponent("ws.port"), limit: 8), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard address == "127.0.0.1", let port = UInt16(portText), port > 0,
              let url = URL(string: "ws://127.0.0.1:\(port)") else { throw ProbeError(reason: .invalidEndpoint) }
        return url
    }

    static func readKey(_ url: URL) throws -> String {
        let data = try readOwnedFile(url, limit: 4096, mode: 0o600)
        guard let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty, key.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !$0.properties.isWhitespace }) else {
            throw ProbeError(reason: .invalidInput)
        }
        return key
    }

    static func validateArtifact(_ url: URL,
        assess: @Sendable (URL) async throws -> Bool = { url in
            let check = try ProbeChild(executable: URL(fileURLWithPath: "/usr/sbin/spctl"),
                arguments: ["--assess", "--type", "execute", url.path])
            return try await check.wait(seconds: 30).status == 0
        }) async throws {
        let header = try readOwnedFile(url, limit: 536_870_912, prefix: 8)
        guard header.elementsEqual([0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0, 0, 1]),
              FileManager.default.isExecutableFile(atPath: url.path) else { throw ProbeError(reason: .invalidArtifact) }
        guard try await assess(url) else { throw ProbeError(reason: .trustFailed) }
    }

    static func startSoloist(executable: URL, keyFile: URL, directory: URL,
                             deviceName: String) async throws -> OwnedSoloistProbe {
        let key = try readKey(keyFile)
        for name in ["data", "cache"] {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent(name),
                withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let dataDirectory = directory.appendingPathComponent("data")
        let child = try ProbeChild(executable: executable, arguments: [
            "--device-name", deviceName, "--api-key", key, "--data-dir", dataDirectory.path,
            "--cache-dir", directory.appendingPathComponent("cache").path,
            "--cache-size", "100", "--initial-volume", "0", "--ws", "127.0.0.1:0",
        ])
        do {
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                try Task.checkCancellation()
                guard await child.isRunning else { throw ProbeError(reason: .processFailed) }
                if let url = try? endpoint(in: dataDirectory) {
                    return OwnedSoloistProbe(child: child, endpoint: url)
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw ProbeError(reason: .timeout)
        } catch {
            await child.stop()
            throw error
        }
    }
}

struct SoloistWireState {
    let generation: UUID
    private(set) var authGeneration: UInt64 = 0
    private(set) var paired = false

    mutating func apply(_ data: Data, at date: Date) throws -> SoloistProbeSnapshot? {
        guard data.count <= 1_048_576,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { throw ProbeError(reason: .invalidResponse) }
        if type == "auth_state" {
            guard let loggedIn = object["logged_in"] as? Bool else { throw ProbeError(reason: .invalidResponse) }
            authGeneration &+= 1
            paired = loggedIn
            return nil
        }
        if type == "error" { throw ProbeError(reason: paired ? .invalidResponse : .notPaired) }
        guard type == "playback_state" else { return nil }
        guard paired, let active = object["is_active"] as? Bool,
              let status = object["status"] as? String,
              let position = object["position"] as? [String: Any],
              let ms = position["position_ms"] as? Double,
              let timestamp = position["timestamp_ms"] as? Double,
              let speed = position["speed"] as? Double,
              ms.isFinite, ms >= 0, timestamp.isFinite, timestamp >= 0, speed.isFinite,
              (0...4).contains(speed) else { throw ProbeError(reason: .invalidResponse) }
        let elapsed = date.timeIntervalSince1970 * 1000 - timestamp
        guard elapsed >= -2000, elapsed < 86_400_000 else { throw ProbeError(reason: .staleObservation) }
        let item = object["item"] as? [String: Any]
        return SoloistProbeSnapshot(generation: generation, authGeneration: authGeneration, paired: paired,
            active: active, itemURI: item?["uri"] as? String, positionMs: ms + max(0, elapsed) * speed,
            playing: status == "playing" && speed > 0, observedAt: date)
    }
}

actor OwnedSoloistProbe {
    let generation = UUID()
    let child: ProbeChild
    private let session: URLSession
    private let socket: URLSessionWebSocketTask
    private var state: SoloistWireState

    init(child: ProbeChild, endpoint: URL) {
        self.child = child
        session = probeSession()
        socket = session.webSocketTask(with: endpoint)
        socket.maximumMessageSize = 1_048_576
        state = SoloistWireState(generation: generation)
        socket.resume()
    }

    func snapshot() async throws -> SoloistProbeSnapshot {
        let socket = self.socket
        do {
            return try await withProbeTimeout(seconds: 30) { [self] in
                try await withTaskCancellationHandler {
                    try await socket.send(.string(#"{"type":"command","command":"get_state"}"#))
                    while true {
                        let message = try await socket.receive()
                        let data: Data
                        switch message {
                        case let .data(value): data = value
                        case let .string(value): data = Data(value.utf8)
                        @unknown default: throw ProbeError(reason: .invalidResponse)
                        }
                        if let snapshot = try await self.apply(data) { return snapshot }
                    }
                } onCancel: { socket.cancel(with: .goingAway, reason: nil) }
            }
        } catch let error as ProbeError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw ProbeError(reason: .observationLost) }
    }

    private func apply(_ data: Data) throws -> SoloistProbeSnapshot? { try state.apply(data, at: .now) }

    func stop() async {
        socket.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
        await child.stop()
    }
}
