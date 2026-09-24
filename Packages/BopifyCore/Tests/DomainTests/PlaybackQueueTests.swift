import Foundation
import Testing
@testable import BopifyDomain

@Suite("Queue events")
struct PlaybackQueueTests {
    @Test func duplicateURIsKeepDistinctTargets() throws {
        let data = Data(#"{"type":"queueChanged","generation":12,"previous":[],"current":null,"next":[{"id":"a","uri":"spotify:track:same","rawNextIndex":0},{"id":"b","uri":"spotify:track:same","rawNextIndex":1}]}"#.utf8)
        guard case let .queueChanged(queue) = try JSONDecoder().decode(PlaybackEvent.self, from: data) else {
            Issue.record("expected queueChanged"); return
        }
        #expect(queue.next[0].id != queue.next[1].id)
        #expect(queue.next[1].target == QueueTarget(generation: 12, rawNextIndex: 1))
    }
    @Test func duplicateVisualIDsAreRejected() {
        let data = Data(#"{"type":"queueChanged","generation":12,"previous":[],"current":null,"next":[{"id":"a","uri":"spotify:track:same","rawNextIndex":0},{"id":"a","uri":"spotify:track:same","rawNextIndex":1}]}"#.utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(PlaybackEvent.self, from: data) }
    }
    @Test func unsupportedEntryIsPreservedButCannotBeSelected() throws {
        let data = Data(#"{"type":"queueChanged","generation":12,"previous":[],"current":null,"next":[{"id":"a","uri":"spotify:local:file","rawNextIndex":0}]}"#.utf8)
        guard case let .queueChanged(queue) = try JSONDecoder().decode(PlaybackEvent.self, from: data) else { Issue.record("expected queue"); return }
        #expect(queue.next.count == 1)
        #expect(queue.next[0].target == nil)
        #expect(queue.next[0].metadataFailed)
    }
    @Test func decodesModesAndNonfatalRejection() throws {
        #expect(try decode(#"{"type":"shuffleChanged","enabled":true}"#) == .shuffleChanged(true))
        #expect(try decode(#"{"type":"repeatChanged","mode":"track"}"#) == .repeatChanged(.track))
        #expect(try decode(#"{"type":"commandRejected","reason":"staleQueue"}"#) == .commandRejected("staleQueue"))
        #expect(throws: (any Error).self) { try decode(#"{"type":"repeatChanged","mode":"invalid"}"#) }
    }
    @Test func nullableMetadataRetainsItsGeneration() throws {
        #expect(try decode(#"{"type":"queueMetadata","generation":4,"entryID":"a","track":null}"#) == .queueMetadata(generation: 4, entryID: "a", track: nil))
    }
    private func decode(_ text: String) throws -> PlaybackEvent {
        try JSONDecoder().decode(PlaybackEvent.self, from: Data(text.utf8))
    }
}
