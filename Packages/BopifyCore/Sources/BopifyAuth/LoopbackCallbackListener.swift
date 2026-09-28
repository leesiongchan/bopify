import Foundation
import Network
import os
import BopifyDomain

public enum CallbackError: Error, Hashable, Sendable {
    case invalidCallback, accessDenied, stateMismatch, listenerFailed, cancelled
}

/// A single-shot HTTP listener on 127.0.0.1 with an assigned or fixed port.
///
/// Spotify rejects `localhost` but permits loopback IP literals, and those
/// alone may use a dynamically assigned port -- which is why librespot's
/// client ID is registered as `http://127.0.0.1/login` with no port.
public actor LoopbackCallbackListener {
    private let expectedState: String
    private var listener: NWListener?
    private var startContinuation: CheckedContinuation<Int, any Error>?
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var continuation: CheckedContinuation<String, any Error>?
    private var pendingResult: Result<String, any Error>?

    public init(expectedState: String) { self.expectedState = expectedState }

    public func start(port: UInt16? = nil) async throws -> Int {
        let parameters = NWParameters.tcp
        let localPort: NWEndpoint.Port = port.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: localPort)
        let listener: NWListener
        do { listener = try NWListener(using: parameters) }
        catch { throw CallbackError.listenerFailed }
        self.listener = listener

        listener.stateUpdateHandler = { [weak self] state in
            Task { await self?.handleState(state) }
        }

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                Task { await self.handle(requestLine: request, on: connection) }
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
            listener.start(queue: .main)
        }
    }

    private func handleState(_ state: NWListener.State) {
        if case .cancelled = state {
            startContinuation?.resume(throwing: CallbackError.cancelled)
            startContinuation = nil
            stopContinuation?.resume()
            stopContinuation = nil
            listener = nil
            return
        }
        guard let startContinuation else { return }
        switch state {
        case .ready:
            guard let port = listener?.port?.rawValue, port != 0 else {
                self.startContinuation = nil
                startContinuation.resume(throwing: CallbackError.listenerFailed)
                listener?.cancel()
                listener = nil
                return
            }
            self.startContinuation = nil
            BopifyLog.callback.debug("listener bound port=\(port, privacy: .public)")
            startContinuation.resume(returning: Int(port))
        case .failed, .waiting:
            self.startContinuation = nil
            BopifyLog.callback.error("callback listener could not bind")
            startContinuation.resume(throwing: CallbackError.listenerFailed)
            listener?.cancel()
            listener = nil
        default:
            break
        }
    }

    public func waitForCallback() async throws -> String {
        if let pendingResult {
            self.pendingResult = nil
            return try pendingResult.get()
        }
        return try await withCheckedThrowingContinuation { self.continuation = $0 }
    }

    public func stop() async {
        if let listener {
            await withCheckedContinuation { continuation in
                stopContinuation = continuation
                listener.cancel()
            }
        }
        deliver(.failure(CallbackError.cancelled))
    }

    /// The single point of decision between resuming a waiter and buffering the
    /// result, so a request that arrives before `waitForCallback()` is called
    /// can't be dropped on the floor.
    private func deliver(_ result: Result<String, any Error>) {
        if let continuation {
            self.continuation = nil
            continuation.resume(with: result)
        } else if pendingResult == nil {
            // First outcome wins: a delivered code must not be overwritten by a
            // later stop(), and a stopped listener must not be revived by a late
            // request.
            pendingResult = result
        }
    }

    private func handle(requestLine: String, on connection: NWConnection) {
        defer { connection.cancel() }
        BopifyLog.callback.info("received callback")

        respond(on: connection)

        guard let path = requestLine.split(separator: " ").dropFirst().first,
              let components = URLComponents(string: "http://127.0.0.1\(path)") else {
            deliver(.failure(CallbackError.invalidCallback)); return
        }
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        if query["error"] == "access_denied" { deliver(.failure(CallbackError.accessDenied)); return }
        guard query["state"] == expectedState else {
            BopifyLog.callback.error("callback state did not match expected state")
            deliver(.failure(CallbackError.stateMismatch)); return
        }
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
