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
    private let expectedPath: String
    private struct Request {
        let connection: NWConnection
        let deadline: Task<Void, Never>
    }
    private var requests: [UUID: Request] = [:]
    private var acceptedResult: Result<String, any Error>?
    private var listener: NWListener?
    private var listenerID: UUID?
    private var startContinuation: CheckedContinuation<Int, any Error>?
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<String, any Error>?
    private var pendingResult: Result<String, any Error>?

    public init(expectedState: String, expectedPath: String = "/login") {
        self.expectedState = expectedState
        self.expectedPath = expectedPath
    }

    public func start(port: UInt16? = nil) async throws -> Int {
        try Task.checkCancellation()
        guard listener == nil, continuation == nil, port != 0 else { throw CallbackError.listenerFailed }
        acceptedResult = nil
        pendingResult = nil
        let parameters = NWParameters.tcp
        let localPort: NWEndpoint.Port = port.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: localPort)
        let listener: NWListener
        do { listener = try NWListener(using: parameters) }
        catch { throw CallbackError.listenerFailed }
        self.listener = listener
        let id = UUID()
        listenerID = id

        listener.stateUpdateHandler = { [weak self] state in
            Task { await self?.handleState(state, id: id) }
        }

        listener.newConnectionHandler = { [weak self] connection in
            Task {
                guard let self else { connection.cancel(); return }
                await self.accept(connection, listenerID: id)
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
            listener.start(queue: .main)
        }
    }

    private func handleState(_ state: NWListener.State, id: UUID) {
        guard listenerID == id else { return }
        if case .cancelled = state {
            startContinuation?.resume(throwing: CallbackError.cancelled)
            startContinuation = nil
            deliver(acceptedResult ?? .failure(CallbackError.cancelled))
            finishListener()
            return
        }
        switch state {
        case .ready:
            guard stopWaiters.isEmpty, let startContinuation else { return }
            guard let port = listener?.port?.rawValue, port != 0 else {
                self.startContinuation = nil
                startContinuation.resume(throwing: CallbackError.listenerFailed)
                listener?.cancel()
                finishListener()
                return
            }
            self.startContinuation = nil
            BopifyLog.callback.debug("listener bound port=\(port, privacy: .public)")
            startContinuation.resume(returning: Int(port))
        case .failed, .waiting:
            let pendingStart = startContinuation
            self.startContinuation = nil
            BopifyLog.callback.error("callback listener could not bind")
            pendingStart?.resume(throwing: CallbackError.listenerFailed)
            listener?.cancel()
            finishListener()
            deliver(acceptedResult ?? .failure(CallbackError.listenerFailed))
        default:
            break
        }
    }

    private func finishListener() {
        closeRequests()
        listener = nil
        listenerID = nil
        let waiters = stopWaiters
        stopWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    public func waitForCallback() async throws -> String {
        if let pendingResult { return try pendingResult.get() }
        guard continuation == nil else { throw CallbackError.invalidCallback }
        return try await withCheckedThrowingContinuation { self.continuation = $0 }
    }

    public func stop() async {
        deliver(acceptedResult ?? .failure(CallbackError.cancelled))
        closeRequests()
        if let listener {
            await withCheckedContinuation { continuation in
                let firstStop = stopWaiters.isEmpty
                stopWaiters.append(continuation)
                if firstStop { listener.cancel() }
            }
        }
    }

    /// The single point of decision between resuming a waiter and buffering the
    /// result, so a request that arrives before `waitForCallback()` is called
    /// can't be dropped on the floor.
    private func deliver(_ result: Result<String, any Error>) {
        guard pendingResult == nil else { return }
        pendingResult = result
        if let continuation {
            self.continuation = nil
            continuation.resume(with: result)
        }
    }

    private func accept(_ connection: NWConnection, listenerID id: UUID) {
        guard listenerID == id, pendingResult == nil, acceptedResult == nil,
              stopWaiters.isEmpty, requests.count < 32 else { connection.cancel(); return }
        let requestID = UUID()
        let deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            await self?.expireRequest(requestID, listenerID: id)
        }
        requests[requestID] = Request(connection: connection, deadline: deadline)
        connection.start(queue: .main)
        receive(requestID, listenerID: id, buffered: Data())
    }

    private func receive(_ requestID: UUID, listenerID id: UUID, buffered: Data) {
        guard listenerID == id, let request = requests[requestID] else { return }
        request.connection.receive(minimumIncompleteLength: 1, maximumLength: 8192 - buffered.count) { [weak self] data, _, complete, error in
            Task { await self?.received(data, complete: complete, failed: error != nil,
                                        requestID: requestID, listenerID: id, buffered: buffered) }
        }
    }

    private func received(_ data: Data?, complete: Bool, failed: Bool,
                          requestID: UUID, listenerID id: UUID, buffered: Data) {
        guard listenerID == id, requests[requestID] != nil else { return }
        var bytes = buffered
        if let data { bytes.append(data) }
        if let end = bytes.range(of: Data([13, 10, 13, 10])) {
            guard let lineEnd = bytes.range(of: Data([13, 10])), lineEnd.lowerBound <= end.lowerBound,
                  let line = String(data: bytes[..<lineEnd.lowerBound], encoding: .utf8) else {
                respond(requestID, listenerID: id, status: "400 Bad Request"); return
            }
            handle(requestLine: line, requestID: requestID, listenerID: id)
        } else if failed || complete || bytes.count >= 8192 {
            closeRequest(requestID)
        } else {
            receive(requestID, listenerID: id, buffered: bytes)
        }
    }

    private func expireRequest(_ requestID: UUID, listenerID id: UUID) {
        guard listenerID == id else { return }
        BopifyLog.callback.debug("callback connection deadline expired")
        closeRequest(requestID)
    }

    private func closeRequest(_ id: UUID) {
        guard let request = requests.removeValue(forKey: id) else { return }
        request.deadline.cancel()
        request.connection.cancel()
    }

    private func closeRequests() {
        for id in Array(requests.keys) { closeRequest(id) }
    }

    private func handle(requestLine: String, requestID: UUID, listenerID id: UUID) {
        guard acceptedResult == nil, pendingResult == nil else {
            respond(requestID, listenerID: id, status: "409 Conflict"); return
        }
        let fields = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard fields.count == 3, fields[0] == "GET", ["HTTP/1.0", "HTTP/1.1"].contains(fields[2]),
              fields[1].hasPrefix("/"), !fields[1].hasPrefix("//"),
              let components = URLComponents(string: "http://127.0.0.1\(fields[1])"),
              components.percentEncodedPath == expectedPath, components.fragment == nil else {
            respond(requestID, listenerID: id, status: "400 Bad Request"); return
        }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard query.updateValue(item.value ?? "", forKey: item.name) == nil else {
                respond(requestID, listenerID: id, status: "400 Bad Request"); return
            }
        }
        guard query["state"] == expectedState,
              !(query["code"] != nil && query["error"] != nil) else {
            BopifyLog.callback.debug("rejected unrelated or malformed callback")
            respond(requestID, listenerID: id, status: "400 Bad Request"); return
        }
        let result: Result<String, any Error>
        if let error = query["error"] {
            guard !error.isEmpty else {
                respond(requestID, listenerID: id, status: "400 Bad Request"); return
            }
            result = .failure(error == "access_denied" ? CallbackError.accessDenied : CallbackError.invalidCallback)
        } else if let code = query["code"], !code.isEmpty {
            result = .success(code)
        } else {
            respond(requestID, listenerID: id, status: "400 Bad Request"); return
        }
        acceptedResult = result
        BopifyLog.callback.info("accepted authorization callback")
        respond(requestID, listenerID: id, status: "200 OK", result: result)
    }

    private func respond(_ requestID: UUID, listenerID id: UUID, status: String,
                         result: Result<String, any Error>? = nil) {
        guard let request = requests[requestID] else { return }
        let body = result == nil ? "Invalid callback." : "<html><body><h1>Bopify</h1><p>You can close this tab.</p></body></html>"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        // Finish the browser response before waking consent, whose caller stops the listener.
        request.connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            Task { await self?.responseSent(requestID, listenerID: id, result: result) }
        })
    }

    private func responseSent(_ requestID: UUID, listenerID id: UUID, result: Result<String, any Error>?) {
        guard listenerID == id else { return }
        closeRequest(requestID)
        if let result { deliver(result) }
    }
}
