import Foundation
import Testing
import BopifyDomain
@testable import BopifyPlayback

@Suite("EventBridge artist songs", .timeLimit(.minutes(1)))
struct EventBridgeArtistTests {
    private let track = SpotifyURI("spotify:track:source")!

    @Test func synchronousReplyMatchesItsSourceTrack() async throws {
        let bridge = EventBridge()
        let result = try await bridge.artistTopTracks(for: track) { id in
            emit(reply(id: id), into: bridge)
        }
        #expect(result.trackURI == track)
        #expect(result.artistName == "Singer")
        bridge.finish()
    }

    @Test func sameTrackRequestsMatchTheirArtistWhenRepliesArriveBackwards() async throws {
        let bridge = EventBridge()
        let (requests, sent) = AsyncStream.makeStream(of: UInt64.self)
        var ids = requests.makeAsyncIterator()
        let first = Task { try await bridge.artistTopTracks(for: track) { sent.yield($0) } }
        let firstID = try #require(await ids.next())
        let second = Task { try await bridge.artistTopTracks(for: track) { sent.yield($0) } }
        let secondID = try #require(await ids.next())
        emit(reply(id: secondID).replacingOccurrences(of: "Singer", with: "Featured"), into: bridge)
        emit(reply(id: firstID), into: bridge)
        #expect(try await first.value.artistName == "Singer")
        #expect(try await second.value.artistName == "Featured")
        bridge.finish()
    }

    @Test func wrongTrackFailsInsteadOfShowingStaleSongs() async {
        let bridge = EventBridge()
        await #expect(throws: ArtistTopTracksFailure.unavailable) {
            _ = try await bridge.artistTopTracks(for: track) { id in
                emit(reply(id: id, source: "spotify:track:other"), into: bridge)
            }
        }
        bridge.finish()
    }

    @Test func cancellationAndFinishReleasePendingRequests() async {
        let bridge = EventBridge()
        let (requests, sent) = AsyncStream.makeStream(of: UInt64.self)
        let pending = Task { try await bridge.artistTopTracks(for: track) { sent.yield($0) } }
        for await _ in requests { break }
        pending.cancel()
        await #expect(throws: CancellationError.self) { _ = try await pending.value }
        bridge.finish()
        await #expect(throws: PlayerError.playbackSessionLost) {
            _ = try await bridge.artistTopTracks(for: track) { _ in Issue.record("Must not send after finish") }
        }
    }

    @Test func malformedReplyFailsItsCaller() async {
        let bridge = EventBridge()
        await #expect(throws: ArtistTopTracksFailure.unavailable) {
            _ = try await bridge.artistTopTracks(for: track) { id in
                emit(#"{"type":"artistTopTracks","requestID":\#(id),"tracks":"invalid"}"#, into: bridge)
            }
        }
        bridge.finish()
    }

    @Test(arguments: [false, true])
    func pendingRequestsFailWhenEngineStops(sessionLost: Bool) async {
        let bridge = EventBridge()
        let (requests, sent) = AsyncStream.makeStream(of: UInt64.self)
        let pending = Task { try await bridge.artistTopTracks(for: track) { sent.yield($0) } }
        for await _ in requests { break }
        if sessionLost { emit(#"{"type":"sessionLost","reason":"commandFailed"}"#, into: bridge) }
        else { bridge.finish() }
        await #expect(throws: PlayerError.playbackSessionLost) { _ = try await pending.value }
        bridge.finish()
    }

    @Test @MainActor func missingReplyExpiresAndReleasesItsTimer() async {
        let clock = RecoveryTestClock()
        let bridge = EventBridge(lyricSleep: { try await Task.sleep(for: $0) },
                                 artistSleep: { try await clock.sleep(for: $0) })
        let pending = Task { try await bridge.artistTopTracks(for: track) { @Sendable _ in } }
        for _ in 0..<1000 {
            if !clock.pendingDelays.isEmpty { break }
            await Task.yield()
        }
        #expect(clock.pendingDelays == [.seconds(35)])
        clock.advance(by: .seconds(35))
        await #expect(throws: ArtistTopTracksFailure.network) { _ = try await pending.value }
        #expect(clock.pendingDelays.isEmpty)
        bridge.finish()
    }

    private func reply(id: UInt64, source: String = "spotify:track:source") -> String {
        #"{"type":"artistTopTracks","requestID":\#(id),"trackURI":"\#(source)","artistURI":"spotify:artist:singer","artistName":"Singer","tracks":[]}"#
    }

    private func emit(_ json: String, into bridge: EventBridge) {
        Array(json.utf8).withUnsafeBytes { bridge.yield(rawJSON: $0) }
    }
}
