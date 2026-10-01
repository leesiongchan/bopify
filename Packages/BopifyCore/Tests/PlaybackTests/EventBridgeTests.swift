import Testing
import Foundation
@testable import BopifyPlayback
import BopifyDomain
import CBopifyCore

@Suite("EventBridge")
struct EventBridgeTests {
    @Test func deliversAnEventPushedFromABackgroundThread() async throws {
        let bridge = EventBridge()
        let json = Array(#"{"type":"playing","positionMs":4200}"#.utf8)

        // The context is taken and dropped on the pushing thread: a raw
        // pointer is not Sendable, and this is where Rust holds it anyway.
        Thread.detachNewThread {
            let ctx = bridge.retainedContext()
            defer { EventBridge.releaseContext(ctx) }
            json.withUnsafeBufferPointer { buffer in
                bopifyEventTrampoline(buffer.baseAddress!, UInt(buffer.count), ctx)
            }
        }

        var iterator = bridge.events.makeAsyncIterator()
        let event = await iterator.next()
        #expect(event == .playing(positionMs: 4200))
    }

    @Test func dropsMalformedPayloadsInsteadOfCrashing() async throws {
        let bridge = EventBridge()
        let bad = Array("not json".utf8)
        let good = Array(#"{"type":"endOfTrack"}"#.utf8)

        Thread.detachNewThread {
            let ctx = bridge.retainedContext()
            defer { EventBridge.releaseContext(ctx) }
            bad.withUnsafeBufferPointer { bopifyEventTrampoline($0.baseAddress!, UInt($0.count), ctx) }
            good.withUnsafeBufferPointer { bopifyEventTrampoline($0.baseAddress!, UInt($0.count), ctx) }
        }

        var iterator = bridge.events.makeAsyncIterator()
        #expect(await iterator.next() == .endOfTrack)
    }

    /// The one obligation the Rust side cannot own: `ctx` must outlive
    /// `bopify_engine_destroy`. The retain is what makes losing the owning
    /// reference early a leak rather than a use-after-free on a Rust thread.
    @Test func theRetainedContextOutlivesItsOwningReference() async throws {
        var owner: EventBridge? = EventBridge()
        let events = owner!.events
        let ctx = owner!.retainedContext()
        owner = nil

        let json = Array(#"{"type":"endOfTrack"}"#.utf8)
        json.withUnsafeBufferPointer { bopifyEventTrampoline($0.baseAddress!, UInt($0.count), ctx) }

        var iterator = events.makeAsyncIterator()
        #expect(await iterator.next() == .endOfTrack)
        EventBridge.releaseContext(ctx)
    }

    @Test func finishTerminatesTheStream() async throws {
        let bridge = EventBridge()
        bridge.finish()
        var iterator = bridge.events.makeAsyncIterator()
        #expect(await iterator.next() == nil)
    }

    /// A bridge dropped without an explicit `finish()` must not leave its
    /// consumer awaiting an event that can never arrive.
    @Test func droppingTheBridgeTerminatesTheStream() async throws {
        var owner: EventBridge? = EventBridge()
        let events = owner!.events
        owner = nil

        var iterator = events.makeAsyncIterator()
        #expect(await iterator.next() == nil)
    }
}

@Suite("FFI smoke test")
struct FFISmokeTests {
    /// Proves the xcframework links, the generated header imports, and the
    /// Swift and Rust views of the ABI agree — including that the trampoline
    /// really converts to the C callback type. A null token is rejected
    /// before any network work, so this does not block.
    @Test func rejectsANullTokenWithInvalidArgument() {
        var err: Int32 = 0
        let handle = bopify_engine_create(nil, "Bopify Test", bopifyEventTrampoline, nil, &err)
        #expect(handle == nil)
        #expect(err == -1)
    }
}

/// Pushes payloads in order from one Rust-like background thread.
private func push(_ payloads: [String], into bridge: EventBridge) {
    let encoded = payloads.map { Array($0.utf8) }
    Thread.detachNewThread {
        let ctx = bridge.retainedContext()
        defer { EventBridge.releaseContext(ctx) }
        for json in encoded {
            json.withUnsafeBufferPointer { bopifyEventTrampoline($0.baseAddress!, UInt($0.count), ctx) }
        }
    }
}

private func mixJSON(_ id: UInt64) -> String {
    #"{"type":"radio","requestID":\#(id),"seedURI":"spotify:track:s","contextURI":"spotify:playlist:m","tracks":[{"trackUri":"spotify:track:a","title":"A","artists":["X"],"albumTitle":null,"artworkUrl":null,"durationMs":1000}]}"#
}

@Suite("EventBridge radio")
struct EventBridgeRadioTests {
    @Test func aReplyResumesTheRequestWithItsID() async throws {
        let bridge = EventBridge()
        let mix = try await bridge.radio { id in push([mixJSON(id)], into: bridge) }
        #expect(mix.contextURI.rawValue == "spotify:playlist:m")
        #expect(mix.tracks.map(\.uri.rawValue) == ["spotify:track:a"])
    }

    @Test func aFailedReplyThrowsItsReason() async {
        let bridge = EventBridge()
        await #expect(throws: RadioFailure.noMix) {
            _ = try await bridge.radio { id in
                push([#"{"type":"radioFailed","requestID":\#(id),"seedURI":"spotify:track:s","reason":"noMix"}"#], into: bridge)
            }
        }
    }

    @Test func aRejectedSendThrowsWithoutWaiting() async {
        let bridge = EventBridge()
        await #expect(throws: PlayerError.playbackSessionLost) {
            _ = try await bridge.radio { _ in throw PlayerError.playbackSessionLost }
        }
    }

    @Test func finishFailsRequestsStillWaiting() async {
        let bridge = EventBridge()
        let waiting = Task { try await bridge.radio { _ in } }
        try? await Task.sleep(for: .milliseconds(20))
        bridge.finish()
        await #expect(throws: PlayerError.playbackSessionLost) { _ = try await waiting.value }
    }

    @Test func cancellingTheCallerStopsItsWait() async {
        let bridge = EventBridge()
        let waiting = Task { try await bridge.radio { _ in } }
        try? await Task.sleep(for: .milliseconds(20))
        waiting.cancel()
        await #expect(throws: CancellationError.self) { _ = try await waiting.value }
    }

    @Test func radioRepliesNeverReachThePlaybackStream() async {
        let bridge = EventBridge()
        push([mixJSON(999), #"{"type":"endOfTrack"}"#], into: bridge)
        var iterator = bridge.events.makeAsyncIterator()
        #expect(await iterator.next() == .endOfTrack)
    }
}
