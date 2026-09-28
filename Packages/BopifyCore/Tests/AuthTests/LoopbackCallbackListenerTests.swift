import Testing
import Foundation
@testable import BopifyAuth

@Suite("LoopbackCallbackListener")
struct LoopbackCallbackListenerTests {
    private func get(_ url: URL) async throws {
        _ = try? await URLSession.shared.data(from: url)
    }

    @Test func bindsAnEphemeralPort() async throws {
        let listener = LoopbackCallbackListener(expectedState: "s")
        let port = try await listener.start()
        #expect(port > 0)
        await listener.stop()
    }

    @Test func bindsRequestedPortAndRejectsAnOccupiedPort() async throws {
        let first = LoopbackCallbackListener(expectedState: "first")
        let port = try await first.start()
        let second = LoopbackCallbackListener(expectedState: "second")
        await #expect(throws: CallbackError.listenerFailed) {
            _ = try await second.start(port: UInt16(port))
        }
        await first.stop()
        #expect(try await second.start(port: UInt16(port)) == port)
        await second.stop()
    }

    @Test func returnsTheAuthorizationCode() async throws {
        let listener = LoopbackCallbackListener(expectedState: "state123")
        let port = try await listener.start()

        async let code = listener.waitForCallback()
        try await get(URL(string: "http://127.0.0.1:\(port)/callback?code=abc123&state=state123")!)

        #expect(try await code == "abc123")
        await listener.stop()
    }

    @Test func rejectsAMismatchedState() async throws {
        let listener = LoopbackCallbackListener(expectedState: "expected")
        let port = try await listener.start()

        // `async let` bindings can't be captured by a closure, so the concurrent
        // wait uses a `Task` instead -- `#expect(throws:)` can capture `.value`.
        let result = Task { try await listener.waitForCallback() }
        try await get(URL(string: "http://127.0.0.1:\(port)/callback?code=abc&state=attacker")!)

        await #expect(throws: CallbackError.stateMismatch) { try await result.value }
        await listener.stop()
    }

    @Test func rejectsDuplicateOAuthParametersWithoutCrashing() async throws {
        let listener = LoopbackCallbackListener(expectedState: "expected")
        let port = try await listener.start()
        let result = Task { try await listener.waitForCallback() }
        try await get(URL(string: "http://127.0.0.1:\(port)/callback?code=abc&state=expected&state=attacker")!)
        await #expect(throws: CallbackError.invalidCallback) { try await result.value }
        await listener.stop()
    }

    @Test func surfacesUserDenial() async throws {
        let listener = LoopbackCallbackListener(expectedState: "s")
        let port = try await listener.start()

        let result = Task { try await listener.waitForCallback() }
        try await get(URL(string: "http://127.0.0.1:\(port)/callback?error=access_denied&state=s")!)

        await #expect(throws: CallbackError.accessDenied) { try await result.value }
        await listener.stop()
    }

    @Test func stopCancelsAPendingWait() async throws {
        let listener = LoopbackCallbackListener(expectedState: "s")
        _ = try await listener.start()

        let result = Task { try await listener.waitForCallback() }
        await listener.stop()

        await #expect(throws: CallbackError.cancelled) { try await result.value }
    }

    @Test func concurrentStopsBothComplete() async throws {
        let listener = LoopbackCallbackListener(expectedState: "s")
        _ = try await listener.start()
        async let first: Void = listener.stop()
        async let second: Void = listener.stop()
        _ = await (first, second)
    }
}
