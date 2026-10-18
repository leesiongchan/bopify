import Foundation
import BopifyDomain

/// Carries the entire automated test suite for everything above the seam.
public final class StubPlaybackEngine: PlaybackEngine, @unchecked Sendable {
    public let events: AsyncStream<PlaybackEvent>
    private let continuation: AsyncStream<PlaybackEvent>.Continuation
    private let lock = NSLock()
    private var commands: [String] = []
    private var emitted = 0
    private let feed: StubEventFeed
    private let commandDelay: Duration

    public init(eventDelay: Duration = .zero, commandDelay: Duration = .zero) {
        let input = AsyncStream<PlaybackEvent>.makeStream(bufferingPolicy: .unbounded)
        let feed = StubEventFeed(input.stream, delay: eventDelay)
        self.feed = feed
        self.commandDelay = commandDelay
        continuation = input.continuation
        events = AsyncStream(unfolding: { await feed.next() })
    }

    public var recordedCommands: [String] {
        lock.withLock { commands }
    }

    public var emittedEvents: Int { lock.withLock { emitted } }
    public func consumedEvents() async -> Int { await feed.consumed }
    public func emit(_ event: PlaybackEvent) {
        lock.withLock { emitted += 1 }
        continuation.yield(event)
    }

    private func record(_ name: String) async {
        if commandDelay > .zero { try? await Task.sleep(for: commandDelay) }
        lock.withLock { commands.append(name) }
    }

    public func load(_ request: PlayRequest) async throws { await record("load:\(request.contextURI.rawValue)") }
    public func resume() async throws { await record("resume") }
    public func playHere() async throws { await record("playHere") }
    public func pause() async throws { await record("pause") }
    public func next() async throws { await record("next") }
    public func previous() async throws { await record("previous") }
    public func seek(to milliseconds: Int64) async throws { await record("seek:\(milliseconds)") }
    public func setVolume(_ value: Double) async throws { await record("setVolume:\(value)") }
    public func selectQueueEntry(_ target: QueueTarget) async throws { await record("selectQueue:\(target.generation):\(target.rawNextIndex)") }
    public func setShuffle(_ enabled: Bool) async throws { await record("setShuffle:\(enabled)") }
    public func setRepeat(_ mode: RepeatMode) async throws { await record("setRepeat:\(mode.rawValue)") }
    public func requestRadio(seed: SpotifyURI) async throws -> RadioMix {
        await record("radio:\(seed.rawValue)")
        throw RadioFailure.unavailable
    }

    public func requestLyrics(for track: SpotifyURI) async throws -> TrackLyrics {
        await record("lyrics:\(track.rawValue)")
        throw LyricFailure.unavailable
    }

}

private actor StubEventFeed {
    private var iterator: AsyncStream<PlaybackEvent>.Iterator
    private let delay: Duration
    private var delivered = 0
    private(set) var consumed = 0

    init(_ stream: AsyncStream<PlaybackEvent>, delay: Duration) {
        iterator = stream.makeAsyncIterator()
        self.delay = delay
    }

    func next() async -> PlaybackEvent? {
        // The consumer asks for another element only after applying the previous event.
        consumed = delivered
        var iterator = self.iterator
        let event = await iterator.next(isolation: self)
        self.iterator = iterator
        if event != nil {
            if delay > .zero { try? await Task.sleep(for: delay) }
            delivered += 1
        }
        return event
    }
}
