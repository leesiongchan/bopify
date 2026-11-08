import Testing
import Foundation
@testable import BopifyPlayback
import BopifyDomain

@Suite("EventBridge")
struct EventBridgeTests {
    @Test func queueMetadataBurstPreservesReadinessAndPlaybackTransitionsInOrder() async {
        let bridge = EventBridge()
        let ctx = bridge.retainedContext()
        defer { EventBridge.releaseContext(ctx) }
        func send(_ payload: String) {
            Array(payload.utf8).withUnsafeBufferPointer {
                bopifyEventTrampoline($0.baseAddress!, UInt($0.count), ctx)
            }
        }
        send(#"{"type":"connectionReady","outcome":"remote"}"#)
        send(#"{"type":"queueChanged","generation":1,"previous":[],"current":null,"next":[]}"#)
        var expected: [PlaybackEvent] = [.connectionReady(.remote),
            .queueChanged(PlaybackQueue(generation: 1, previous: [], current: nil, next: []))]
        for index in 0..<80 {
            if index == 40 {
                send(#"{"type":"paused","positionMs":3210}"#)
                expected.append(.paused(positionMs: 3210))
            }
            send(#"{"type":"queueMetadata","generation":1,"entryID":"\#(index)","track":null}"#)
            expected.append(.queueMetadata(generation: 1, entryID: String(index), track: nil))
        }
        send(#"{"type":"sessionLost","reason":"spircEnded"}"#)
        expected.append(.sessionLost(.spircEnded))
        bridge.finish()
        var received: [PlaybackEvent] = []
        for await event in bridge.events { received.append(event) }
        #expect(received == expected)
    }

    @Test(arguments: [
        (#"{"type":"playing"}"#, "positionMs"),
        (#"{"type":"trackChanged","trackUri":"spotify:local:a:b:c:1","title":"T","artists":[],"durationMs":1}"#, "trackUri"),
        (#"{"type":"teleported"}"#, "type"),
        ("not json", "root"),
    ])
    func decodeFailuresNameTheFieldWithoutItsValue(json: String, field: String) throws {
        let error = try #require(throws: DecodingError.self) {
            try JSONDecoder().decode(PlaybackEvent.self, from: Data(json.utf8))
        }
        #expect(error.fieldPath == field)
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
    /// `bopify_services_destroy`. The retain is what makes losing the owning
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

private let radioSeed = SpotifyURI("spotify:track:s")!

private func mixJSON(_ id: UInt64, context: String = "spotify:playlist:m", seed: String = "spotify:track:s") -> String {
    #"{"type":"radio","requestID":\#(id),"seedURI":"\#(seed)","contextURI":"\#(context)","tracks":[{"trackUri":"spotify:track:a","title":"A","artists":["X"],"albumTitle":null,"artworkUrl":null,"durationMs":1000}]}"#
}

@Suite("EventBridge radio")
struct EventBridgeRadioTests {
    /// Replies arrive in reverse order; each must still reach the caller that sent its ID.
    @Test func concurrentRequestsEachGetTheReplyCarryingTheirID() async throws {
        let bridge = EventBridge()
        let (sent, sender) = AsyncStream.makeStream(of: (String, UInt64).self)
        let first = Task { try await bridge.radio(seed: radioSeed) { sender.yield(("first", $0)) } }
        let second = Task { try await bridge.radio(seed: radioSeed) { sender.yield(("second", $0)) } }
        // The waiter is registered before `send` runs, so two IDs here means both callers are waiting.
        var ids: [String: UInt64] = [:]
        for await (label, id) in sent {
            ids[label] = id
            if ids.count == 2 { break }
        }
        let replies = ids.sorted { $0.value > $1.value }.map { mixJSON($0.value, context: "spotify:playlist:\($0.key)") }
        push(replies, into: bridge)
        #expect(try await first.value.contextURI.rawValue == "spotify:playlist:first")
        #expect(try await second.value.contextURI.rawValue == "spotify:playlist:second")
    }

    @Test @MainActor func aMissingReplyExpiresAndReleasesItsTimer() async {
        let clock = RecoveryTestClock()
        let bridge = EventBridge(lyricSleep: { try await Task.sleep(for: $0) },
                                 radioSleep: { try await clock.sleep(for: $0) })
        let pending = Task { try await bridge.radio(seed: radioSeed) { @Sendable _ in } }
        for _ in 0..<1000 {
            if !clock.pendingDelays.isEmpty { break }
            await Task.yield()
        }
        #expect(clock.pendingDelays == [.seconds(35)])
        clock.advance(by: .seconds(35))
        await #expect(throws: RadioFailure.network) { _ = try await pending.value }
        #expect(clock.pendingDelays.isEmpty)
        bridge.finish()
    }

    @Test @MainActor func aReplyCancelsItsTimer() async throws {
        let clock = RecoveryTestClock()
        let bridge = EventBridge(lyricSleep: { try await Task.sleep(for: $0) },
                                 radioSleep: { try await clock.sleep(for: $0) })
        _ = try await bridge.radio(seed: radioSeed) { @Sendable id in push([mixJSON(id)], into: bridge) }
        for _ in 0..<1000 {
            if clock.pendingDelays.isEmpty { break }
            await Task.yield()
        }
        #expect(clock.pendingDelays.isEmpty)
        bridge.finish()
    }

    @Test func aReplyForAnotherSeedFailsTheRequest() async {
        let bridge = EventBridge()
        await #expect(throws: RadioFailure.unavailable) {
            _ = try await bridge.radio(seed: radioSeed) { id in push([mixJSON(id, seed: "spotify:track:other")], into: bridge) }
        }
    }

    @Test func aFailedReplyThrowsItsReason() async {
        let bridge = EventBridge()
        await #expect(throws: RadioFailure.noMix) {
            _ = try await bridge.radio(seed: radioSeed) { id in
                push([#"{"type":"radioFailed","requestID":\#(id),"seedURI":"spotify:track:s","reason":"noMix"}"#], into: bridge)
            }
        }
    }

    @Test func aRejectedSendThrowsWithoutWaiting() async {
        let bridge = EventBridge()
        await #expect(throws: PlayerError.playbackSessionLost) {
            _ = try await bridge.radio(seed: radioSeed) { _ in throw PlayerError.playbackSessionLost }
        }
    }

    @Test func cancellingTheCallerStopsItsWait() async {
        let bridge = EventBridge()
        let waiting = Task { try await bridge.radio(seed: radioSeed) { _ in } }
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
