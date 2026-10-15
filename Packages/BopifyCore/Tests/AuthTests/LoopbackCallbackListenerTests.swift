import Testing
import Foundation
import Network
@testable import BopifyAuth

@Suite("LoopbackCallbackListener")
struct LoopbackCallbackListenerTests {
    private func get(_ url: URL) async throws {
        let (_, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
    }

    @Test func bindsAnEphemeralPort() async throws {
        let listener = LoopbackCallbackListener(expectedState: "s", expectedPath: "/callback")
        let port = try await listener.start()
        #expect(port > 0)
        await listener.stop()
    }

    @Test func bindsRequestedPortAndRejectsAnOccupiedPort() async throws {
        let first = LoopbackCallbackListener(expectedState: "first", expectedPath: "/callback")
        let port = try await first.start()
        let second = LoopbackCallbackListener(expectedState: "second", expectedPath: "/callback")
        await #expect(throws: CallbackError.listenerFailed) {
            _ = try await second.start(port: UInt16(port))
        }
        await first.stop()
        #expect(try await second.start(port: UInt16(port)) == port)
        await second.stop()
    }

    @Test func returnsTheAuthorizationCode() async throws {
        let listener = LoopbackCallbackListener(expectedState: "state123", expectedPath: "/callback")
        let port = try await listener.start()

        async let code = listener.waitForCallback()
        try await get(URL(string: "http://127.0.0.1:\(port)/callback?code=abc123&state=state123")!)

        #expect(try await code == "abc123")
        await listener.stop()
    }

    @Test func mismatchedStateDoesNotAbortTheLegitimateCallback() async throws {
        let listener = LoopbackCallbackListener(expectedState: "expected", expectedPath: "/callback")
        let port = try await listener.start()

        // `async let` bindings can't be captured by a closure, so the concurrent
        // wait uses a `Task` instead -- `#expect(throws:)` can capture `.value`.
        let result = Task { try await listener.waitForCallback() }
        _ = try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/callback?code=abc&state=attacker")!)
        try await get(URL(string: "http://127.0.0.1:\(port)/callback?code=VALID&state=expected")!)
        #expect(try await result.value == "VALID")
        await listener.stop()
    }

    @Test func duplicateOAuthParametersDoNotAbortTheLegitimateCallback() async throws {
        let listener = LoopbackCallbackListener(expectedState: "expected", expectedPath: "/callback")
        let port = try await listener.start()
        let result = Task { try await listener.waitForCallback() }
        _ = try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/callback?code=abc&state=expected&state=attacker")!)
        try await get(URL(string: "http://127.0.0.1:\(port)/callback?code=VALID&state=expected")!)
        #expect(try await result.value == "VALID")
        await listener.stop()
    }

    @Test func surfacesUserDenial() async throws {
        let listener = LoopbackCallbackListener(expectedState: "s", expectedPath: "/callback")
        let port = try await listener.start()

        let result = Task { try await listener.waitForCallback() }
        try await get(URL(string: "http://127.0.0.1:\(port)/callback?error=access_denied&state=s")!)

        await #expect(throws: CallbackError.accessDenied) { try await result.value }
        await listener.stop()
    }

    @Test func stopCancelsAPendingWait() async throws {
        let listener = LoopbackCallbackListener(expectedState: "s", expectedPath: "/callback")
        _ = try await listener.start()

        let result = Task { try await listener.waitForCallback() }
        await listener.stop()

        await #expect(throws: CallbackError.cancelled) { try await result.value }
    }

    @Test func concurrentStopsBothComplete() async throws {
        let listener = LoopbackCallbackListener(expectedState: "s", expectedPath: "/callback")
        _ = try await listener.start()
        async let first: Void = listener.stop()
        async let second: Void = listener.stop()
        _ = await (first, second)
    }

    private func rawRequest(port: Int, fragments: [String], finish: Bool = false, onSent: @Sendable () -> Void = {}) async throws -> Data {
        let connection = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
        defer { connection.cancel() }
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, any Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.stateUpdateHandler = nil
                    ready.resume()
                case .failed(let error):
                    connection.stateUpdateHandler = nil
                    ready.resume(throwing: error)
                default: break
                }
            }
            connection.start(queue: .global())
        }
        for fragment in fragments {
            try await withCheckedThrowingContinuation { (sent: CheckedContinuation<Void, any Error>) in
                connection.send(content: Data(fragment.utf8), completion: .contentProcessed { error in
                    if let error { sent.resume(throwing: error) } else { sent.resume() }
                })
            }
            if fragments.count > 1 { try await Task.sleep(for: .milliseconds(30)) }
        }
        if finish {
            try await withCheckedThrowingContinuation { (sent: CheckedContinuation<Void, any Error>) in
                connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { error in
                    if let error { sent.resume(throwing: error) } else { sent.resume() }
                })
            }
        }
        onSent()
        var response = Data()
        while true {
            let (data, complete) = try await withCheckedThrowingContinuation { (received: CheckedContinuation<(Data?, Bool), any Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, complete, error in
                    if let error { received.resume(throwing: error) } else { received.resume(returning: (data, complete)) }
                }
            }
            if let data { response.append(data) }
            if complete { return response }
        }
    }

    @Test func fragmentedRequestCompletesOnlyAfterTheWholeCallbackArrives() async throws {
        let listener = LoopbackCallbackListener(expectedState: "expected", expectedPath: "/callback")
        let port = try await listener.start()
        let result = Task { try await listener.waitForCallback() }
        let response = try? await rawRequest(port: port, fragments: [
            "GET /call", "back?code=FRAGMENTED&sta", "te=expected HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        ])
        await listener.stop()
        #expect(try await result.value == "FRAGMENTED")
        #expect(response.flatMap { String(data: $0, encoding: .utf8) }?.contains("200 OK") == true)
    }

    @Test(arguments: [
        "GET /favicon.ico HTTP/1.1", "GET /other?code=BAD&state=expected HTTP/1.1",
        "POST /callback?code=BAD&state=expected HTTP/1.1", "GET /callback?code=BAD HTTP/1.1",
        "GET /callback?error=access_denied&state=wrong HTTP/1.1",
        "GET /callback?error=access_denied HTTP/1.1",
        "GET /callback?error=&state=expected HTTP/1.1",
        "GET /callback?error&state=expected HTTP/1.1",
        "GET /callback?code=BAD&state=expected&code=SECOND HTTP/1.1",
        "GET http://127.0.0.1/callback?code=BAD&state=expected HTTP/1.1",
        "GET //other/callback?code=BAD&state=expected HTTP/1.1",
        "GET /callback?code=BAD&state=expected#fragment HTTP/1.1",
        "GET /callback?code=BAD&error=access_denied&state=expected HTTP/1.1"
    ]) func unrelatedOrMalformedRequestCannotWinConsent(_ requestLine: String) async throws {
        let listener = LoopbackCallbackListener(expectedState: "expected", expectedPath: "/callback")
        let port = try await listener.start()
        let result = Task { try await listener.waitForCallback() }
        _ = try? await rawRequest(port: port, fragments: [requestLine + "\r\nHost: 127.0.0.1\r\n\r\n"])
        try await get(URL(string: "http://127.0.0.1:\(port)/callback?code=VALID&state=expected")!)
        await listener.stop()
        #expect(try await result.value == "VALID")
    }

    @Test func oversizedOrIncompleteRequestDoesNotConsumeConsent() async throws {
        let listener = LoopbackCallbackListener(expectedState: "expected", expectedPath: "/callback")
        let port = try await listener.start()
        let result = Task { try await listener.waitForCallback() }
        _ = try? await rawRequest(port: port, fragments: ["GET /callback?code=" + String(repeating: "x", count: 9000)])
        _ = try? await rawRequest(port: port, fragments: ["GET /callback?code=TRUNCATED&state=expected"], finish: true)
        try await get(URL(string: "http://127.0.0.1:\(port)/callback?code=VALID&state=expected")!)
        await listener.stop()
        #expect(try await result.value == "VALID")
    }

    @Test(.timeLimit(.minutes(1))) func incompleteConnectionExpiresWithoutConsumingConsent() async throws {
        let listener = LoopbackCallbackListener(expectedState: "expected", expectedPath: "/callback")
        let port = try await listener.start()
        let start = ContinuousClock.now
        _ = try? await rawRequest(port: port, fragments: ["GET /callback?code=INCOMPLETE"])
        #expect(start.duration(to: .now) >= .seconds(4))
        try await get(URL(string: "http://127.0.0.1:\(port)/callback?code=VALID&state=expected")!)
        #expect(try await listener.waitForCallback() == "VALID")
        await listener.stop()
    }

    @Test(.timeLimit(.minutes(1))) func stopClosesIncompleteConnectionsAndRestartAcceptsANewCallback() async throws {
        let listener = LoopbackCallbackListener(expectedState: "expected", expectedPath: "/callback")
        let port = try await listener.start()
        let sent = AsyncStream<Void>.makeStream()
        let request = Task { try? await rawRequest(port: port, fragments: ["GET /callback?code=STALE"], onSent: { sent.continuation.yield(()) }) }
        for await _ in sent.stream { break }
        await listener.stop()
        _ = await request.value
        await #expect(throws: CallbackError.cancelled) { try await listener.waitForCallback() }
        let newPort = try await listener.start()
        try await get(URL(string: "http://127.0.0.1:\(newPort)/callback?code=NEW&state=expected")!)
        #expect(try await listener.waitForCallback() == "NEW")
        _ = try? await rawRequest(port: newPort, fragments: ["GET /callback?code=LATE&state=expected HTTP/1.1\r\n\r\n"])
        #expect(try await listener.waitForCallback() == "NEW")
        await listener.stop()
    }

    @Test func callbackBeforeWaitIsRetainedAndCannotBeOverwritten() async throws {
        let listener = LoopbackCallbackListener(expectedState: "expected", expectedPath: "/callback")
        let port = try await listener.start()
        try await get(URL(string: "http://127.0.0.1:\(port)/callback?code=FIRST&state=expected")!)
        _ = try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/callback?code=SECOND&state=expected")!)
        await listener.stop()
        #expect(try await listener.waitForCallback() == "FIRST")
    }

}
