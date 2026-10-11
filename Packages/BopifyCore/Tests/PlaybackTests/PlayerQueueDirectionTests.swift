import Testing
import Foundation
import BopifyDomain
@testable import BopifyPlayback

@MainActor
@Suite("Player queue direction")
struct PlayerQueueDirectionTests {
    private func entry(_ id: String) -> QueueEntry {
        QueueEntry(id: id, uri: SpotifyURI("spotify:track:duplicate"), target: nil, track: nil, metadataFailed: false)
    }

    private func queue(_ index: Int, generation: UInt64 = 1) -> PlaybackQueue {
        let entries = [entry("a"), entry("b"), entry("c")]
        return PlaybackQueue(generation: generation, previous: Array(entries[..<index]),
                             current: entries[index], next: Array(entries[(index + 1)...]))
    }

    @Test(arguments: [true, false])
    func navigationUsesOccurrenceOrder(_ forward: Bool) {
        let model = PlayerModel()
        model.applyPreviewEvents([.queueChanged(queue(1))])
        #expect(model.queueDirection == .fade)
        model.applyPreviewEvents([.queueChanged(queue(forward ? 2 : 0, generation: 2))])
        #expect(model.queueDirection == (forward ? .next : .previous))
    }

    @Test func metadataBurstPreservesNavigationDirection() {
        let model = PlayerModel()
        model.applyPreviewEvents([.queueChanged(queue(0)), .queueChanged(queue(1, generation: 2))])
        let track = Track(uri: entry("b").uri!, title: "Hydrated", artists: [], albumTitle: nil, artwork: nil, durationMs: 1000)
        model.applyPreviewEvents((0..<50).map { .queueMetadata(generation: 2, entryID: "b", track: $0.isMultiple(of: 2) ? nil : track) })
        #expect(model.state.queue?.current?.track == track)
        #expect(model.queueDirection == .next)
    }

    @Test func unchangedOccurrencePreservesDirectionAndUpdatesNeighbors() {
        let model = PlayerModel()
        model.applyPreviewEvents([.queueChanged(queue(0)), .queueChanged(queue(1, generation: 2)),
                                  .queueChanged(PlaybackQueue(generation: 3, previous: [entry("changed")], current: entry("b"), next: []))])
        #expect(model.queueDirection == .next)
        model.applyPreviewEvents([.queueChanged(PlaybackQueue(generation: 4, previous: [], current: entry("changed"), next: [entry("b")]))])
        #expect(model.queueDirection == .previous)
    }

    @Test(arguments: [PlaybackEvent.activeDeviceChanged(isActive: true), .playing(positionMs: 0), .paused(positionMs: 0)])
    func returningFromAMirrorFades(_ event: PlaybackEvent) {
        let model = PlayerModel()
        let remote = RemotePlayback(deviceName: "Fixture", trackURI: SpotifyURI("spotify:track:remote")!, track: nil,
                                    isPlaying: true, positionMs: 0, durationMs: 1000)
        model.applyPreviewEvents([.queueChanged(queue(0)), .queueChanged(queue(1, generation: 2)),
                                  .activeDeviceChanged(isActive: false), .remotePlayback(remote),
                                  .queueChanged(queue(2, generation: 3)), event])
        #expect(model.state.mirror == nil)
        #expect(model.queueDirection == .fade)
    }

    @Test func unrelatedQueueReplacementFades() {
        let model = PlayerModel()
        model.applyPreviewEvents([.queueChanged(queue(0)), .queueChanged(queue(1, generation: 2)),
                                  .queueChanged(PlaybackQueue(generation: 3, previous: [], current: entry("unrelated"), next: []))])
        #expect(model.queueDirection == .fade)
    }
}
