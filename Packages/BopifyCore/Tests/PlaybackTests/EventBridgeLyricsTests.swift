import Foundation
import Testing
import BopifyDomain
@testable import BopifyPlayback

@Suite("EventBridge lyrics", .timeLimit(.minutes(1)))
@MainActor
struct EventBridgeLyricsTests {
    private let track = SpotifyURI("spotify:track:11dFghVXANMlKmJXsNCbNl")!
    private let other = SpotifyURI("spotify:track:4uLU6hMCjMI75M1A2tKUQC")!

    @Test func synchronousReplyCompletesWithoutOrphanTimer() async throws {
        let clock = RecoveryTestClock()
        let bridge = EventBridge(lyricSleep: { try await clock.sleep(for: $0) })
        let lyrics = try await bridge.lyrics(for: track) { @Sendable id in
            emit(reply(id, track), into: bridge)
            emit(reply(id, other), into: bridge)
        }
        #expect(lyrics.trackURI == track)
        #expect(lyrics.lines == [TrackLyricLine(text: "A quiet street", startTimeMs: 1000)])
        try await assertClean(clock, bridge: bridge)
    }

    @Test func reverseOrderRepliesReachTheirCallers() async throws {
        let clock = RecoveryTestClock()
        let bridge = EventBridge(lyricSleep: { try await clock.sleep(for: $0) })
        let (ids, sent) = AsyncStream.makeStream(of: (SpotifyURI, UInt64).self)
        let first = Task { try await bridge.lyrics(for: track) { @Sendable id in sent.yield((track, id)) } }
        let second = Task { try await bridge.lyrics(for: other) { @Sendable id in sent.yield((other, id)) } }
        var requests: [(SpotifyURI, UInt64)] = []
        for await request in ids {
            requests.append(request)
            if requests.count == 2 { break }
        }
        #expect(requests[0].1 != requests[1].1)
        for (uri, id) in requests.reversed() { emit(reply(id, uri), into: bridge) }
        #expect(try await first.value.trackURI == track)
        #expect(try await second.value.trackURI == other)
        try await assertClean(clock, bridge: bridge)
    }

    @Test func wrongTrackFailsUnavailable() async throws {
        let clock = RecoveryTestClock()
        let bridge = EventBridge(lyricSleep: { try await clock.sleep(for: $0) })
        await #expect(throws: LyricFailure.unavailable) {
            _ = try await bridge.lyrics(for: track) { @Sendable id in emit(reply(id, other), into: bridge) }
        }
        try await assertClean(clock, bridge: bridge)
    }

    @Test func radioAndLyricsWithEqualIDsStaySeparate() async throws {
        let clock = RecoveryTestClock()
        let bridge = EventBridge(lyricSleep: { try await clock.sleep(for: $0) })
        let (ids, sent) = AsyncStream.makeStream(of: (String, UInt64).self)
        let radio = Task { try await bridge.radio(seed: SpotifyURI("spotify:track:s")!) { @Sendable id in sent.yield(("radio", id)) } }
        let lyrics = Task { try await bridge.lyrics(for: track) { @Sendable id in sent.yield(("lyrics", id)) } }
        var requests: [String: UInt64] = [:]
        for await (kind, id) in ids {
            requests[kind] = id
            if requests.count == 2 { break }
        }
        let id = try #require(requests["lyrics"])
        #expect(requests["radio"] == id)
        emit(reply(id, track), into: bridge)
        emit(#"{"type":"radio","requestID":\#(id),"seedURI":"spotify:track:s","contextURI":"spotify:playlist:fixture","tracks":[]}"#, into: bridge)
        #expect(try await lyrics.value.trackURI == track)
        #expect(try await radio.value.contextURI.rawValue == "spotify:playlist:fixture")
        try await assertClean(clock, bridge: bridge)
    }

    @Test(arguments: ["noLyrics", "network", "unavailable", "newReason", "malformed"])
    func failureRepliesCompleteTheirWaiter(reason: String) async throws {
        let clock = RecoveryTestClock()
        let bridge = EventBridge(lyricSleep: { try await clock.sleep(for: $0) })
        let expected = LyricFailure(rawValue: reason) ?? .unavailable
        await #expect(throws: expected) {
            _ = try await bridge.lyrics(for: track) { @Sendable id in
                let json = reason == "malformed"
                    ? #"{"type":"lyrics","requestID":\#(id),"trackURI":"\#(track.rawValue)","lines":"bad"}"#
                    : #"{"type":"lyricsFailed","requestID":\#(id),"trackURI":"\#(track.rawValue)","reason":"\#(reason)"}"#
                emit(json, into: bridge)
            }
        }
        try await assertClean(clock, bridge: bridge)
    }

    @Test func rejectedSendCancelsItsWatchdog() async throws {
        let clock = RecoveryTestClock()
        let bridge = EventBridge(lyricSleep: { try await clock.sleep(for: $0) })
        await #expect(throws: PlayerError.unknown) {
            _ = try await bridge.lyrics(for: track) { @Sendable _ in throw PlayerError.unknown }
        }
        try await assertClean(clock, bridge: bridge)
    }

    @Test(arguments: ["none", "missingID", "invalidID", "negativeID"])
    func lostOrUncorrelatableReplyExpiresAt35Seconds(defect: String) async throws {
        let clock = RecoveryTestClock()
        let bridge = EventBridge(lyricSleep: { try await clock.sleep(for: $0) })
        let request = Task { try await bridge.lyrics(for: track) { @Sendable _ in
            switch defect {
            case "missingID": emit(#"{"type":"lyrics","lines":"private fixture"}"#, into: bridge)
            case "invalidID": emit(#"{"type":"lyrics","requestID":"bad","lines":"private fixture"}"#, into: bridge)
            case "negativeID": emit(#"{"type":"lyricsFailed","requestID":-1,"reason":"network"}"#, into: bridge)
            default: break
            }
        } }
        try await waitUntil { clock.pendingDelays == [.seconds(35)] }
        clock.advance(by: .seconds(34))
        #expect(clock.pendingDelays == [.seconds(35)])
        clock.advance(by: .seconds(1))
        await #expect(throws: LyricFailure.network) { _ = try await request.value }
        try await assertClean(clock, bridge: bridge)
    }

    @Test func cancellationRemovesTheWaiterAndTimer() async throws {
        let clock = RecoveryTestClock()
        let bridge = EventBridge(lyricSleep: { try await clock.sleep(for: $0) })
        let request = Task { try await bridge.lyrics(for: track) { @Sendable _ in } }
        try await waitUntil { clock.pendingDelays == [.seconds(35)] }
        request.cancel()
        await #expect(throws: CancellationError.self) { _ = try await request.value }
        try await assertClean(clock, bridge: bridge)
    }

    @Test func alreadyCancelledCallerDoesNotSend() async throws {
        let clock = RecoveryTestClock()
        let bridge = EventBridge(lyricSleep: { try await clock.sleep(for: $0) })
        let (gate, open) = AsyncStream.makeStream(of: Void.self)
        let request = Task {
            for await _ in gate { break }
            return try await bridge.lyrics(for: track) { @Sendable _ in Issue.record("cancelled request sent") }
        }
        request.cancel()
        open.finish()
        await #expect(throws: CancellationError.self) { _ = try await request.value }
        try await assertClean(clock, bridge: bridge)
    }

    @Test(arguments: ["finish", "sessionLost", "unknownReason"])
    func terminalPathsFailBothChannelsAndRejectNewRequests(path: String) async throws {
        let clock = RecoveryTestClock()
        let bridge = EventBridge(lyricSleep: { try await clock.sleep(for: $0) })
        let (sent, sender) = AsyncStream.makeStream(of: Void.self)
        let radio = Task { try await bridge.radio(seed: SpotifyURI("spotify:track:s")!) { @Sendable _ in sender.yield(()) } }
        let lyrics = Task { try await bridge.lyrics(for: track) { @Sendable _ in sender.yield(()) } }
        var count = 0
        for await _ in sent { count += 1; if count == 2 { break } }
        switch path {
        case "finish": bridge.finish()
        case "unknownReason": emit(#"{"type":"sessionLost","reason":"teleported"}"#, into: bridge)
        default: emit(#"{"type":"sessionLost","reason":"spircEnded"}"#, into: bridge)
        }
        await #expect(throws: PlayerError.playbackSessionLost) { _ = try await lyrics.value }
        await #expect(throws: PlayerError.playbackSessionLost) { _ = try await radio.value }
        await #expect(throws: PlayerError.playbackSessionLost) {
            _ = try await bridge.lyrics(for: track) { @Sendable _ in Issue.record("finished bridge sent") }
        }
        try await assertClean(clock, bridge: bridge)
    }

    @Test func lyricRepliesNeverReachPlaybackEvents() async throws {
        let bridge = EventBridge()
        emit(reply(999, track), into: bridge)
        emit(#"{"type":"lyricsFailed","requestID":"bad","reason":"network"}"#, into: bridge)
        emit(#"{"type":"endOfTrack"}"#, into: bridge)
        bridge.finish()
        var received: [PlaybackEvent] = []
        for await event in bridge.events { received.append(event) }
        #expect(received == [.endOfTrack])
    }

    private func assertClean(_ clock: RecoveryTestClock, bridge: EventBridge) async throws {
        try await waitUntil { clock.pendingDelays.isEmpty }
        clock.advance(by: .seconds(70))
        emit(reply(1, track), into: bridge)
        emit(reply(1, track), into: bridge)
        bridge.finish()
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        try #require(condition(), "clock did not reach the expected state")
    }

    nonisolated private func reply(_ id: UInt64, _ uri: SpotifyURI) -> String {
        #"{"type":"lyrics","requestID":\#(id),"trackURI":"\#(uri.rawValue)","synchronization":"lineSynced","lines":[{"text":"A quiet street","startTimeMs":1000}],"provider":"fixture","providerDisplayName":"Fixture provider","isRightToLeft":false}"#
    }

    nonisolated private func emit(_ json: String, into bridge: EventBridge) {
        Array(json.utf8).withUnsafeBytes { bridge.yield(rawJSON: $0) }
    }
}
