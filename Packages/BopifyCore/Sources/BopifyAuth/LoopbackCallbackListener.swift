import Foundation
import Network

public enum CallbackError: Error, Hashable, Sendable {
    case invalidCallback, accessDenied, stateMismatch, listenerFailed, cancelled
}

/// A single-shot HTTP listener on 127.0.0.1 with an OS-assigned port.
///
/// Spotify rejects `localhost` but permits loopback IP literals, and those
/// alone may use a dynamically assigned port -- which is why the app is
/// registered as `http://127.0.0.1/callback` with no port.
public actor LoopbackCallbackListener {
    private let expectedState: String
    private var listener: NWListener?
    private var continuation: CheckedContinuation<String, any Error>?
    private var pendingResult: Result<String, any Error>?

    public init(expectedState: String) { self.expectedState = expectedState }

    public func start() throws -> Int {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                Task { await self.handle(requestLine: request, on: connection) }
            }
        }
        listener.start(queue: .main)

        // NWListener assigns the port asynchronously; spin briefly for it.
        for _ in 0..<100 {
            if let port = listener.port?.rawValue, port != 0 { return Int(port) }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw CallbackError.listenerFailed
    }

    public func waitForCallback() async throws -> String {
        if let pendingResult {
            self.pendingResult = nil
            return try pendingResult.get()
        }
        return try await withCheckedThrowingContinuation { self.continuation = $0 }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        deliver(.failure(CallbackError.cancelled))
    }

    /// The single point of decision between resuming a waiter and buffering the
    /// result, so a request that arrives before `waitForCallback()` is called
    /// can't be dropped on the floor.
    private func deliver(_ result: Result<String, any Error>) {
        if let continuation {
            self.continuation = nil
            continuation.resume(with: result)
        } else {
            pendingResult = result
        }
    }

    private func handle(requestLine: String, on connection: NWConnection) {
        defer { connection.cancel() }

        respond(on: connection)

        guard let path = requestLine.split(separator: " ").dropFirst().first,
              let components = URLComponents(string: "http://127.0.0.1\(path)") else {
            deliver(.failure(CallbackError.invalidCallback)); return
        }
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        if query["error"] == "access_denied" { deliver(.failure(CallbackError.accessDenied)); return }
        guard query["state"] == expectedState else { deliver(.failure(CallbackError.stateMismatch)); return }
        guard let code = query["code"], !code.isEmpty else { deliver(.failure(CallbackError.invalidCallback)); return }
        deliver(.success(code))
    }

    private func respond(on connection: NWConnection) {
        let body = "<html><body><h1>Bopify</h1><p>You can close this tab.</p></body></html>"
        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in })
    }
}
