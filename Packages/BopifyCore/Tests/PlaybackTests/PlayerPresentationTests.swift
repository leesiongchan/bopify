import Foundation
import Testing
import BopifyDomain
@testable import BopifyPlayback

@Suite("Player presentation")
struct PlayerPresentationTests {
    private func entry(_ id: String) -> QueueEntry {
        QueueEntry(id: id, uri: SpotifyURI("spotify:track:same"), target: nil, track: nil, metadataFailed: false)
    }
    @Test func confirmedOccurrencesDetermineDirection() {
        let first = PlaybackQueue(generation: 1, previous: [entry("p")], current: entry("a"), next: [entry("b")])
        let second = PlaybackQueue(generation: 2, previous: [entry("a")], current: entry("b"), next: [])
        #expect(carouselDirection(old: first, new: second) == .next)
        #expect(carouselDirection(old: second, new: first) == .previous)
    }
    @Test func ambiguousDuplicateReplacementFades() {
        let old = PlaybackQueue(generation: 1, previous: [], current: entry("a"), next: [entry("b")])
        let replacement = PlaybackQueue(generation: 2, previous: [], current: entry("x"), next: [entry("y")])
        #expect(carouselDirection(old: old, new: replacement) == .fade)
        #expect(carouselDirection(old: nil, new: replacement) == .fade)
    }
}
