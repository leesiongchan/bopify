import Foundation
import BopifyDomain

/// Carries the entire automated test suite for everything above the seam.
public final class StubPlaybackEngine: PlaybackEngine, @unchecked Sendable {
    public let events: AsyncStream<PlaybackEvent>
    private let continuation: AsyncStream<PlaybackEvent>.Continuation
    private let lock = NSLock()
    private var commands: [String] = []

    public init() {
        var escaped: AsyncStream<PlaybackEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { escaped = $0 }
        continuation = escaped
    }

    public var recordedCommands: [String] {
        lock.withLock { commands }
    }

    public func emit(_ event: PlaybackEvent) { continuation.yield(event) }

    private func record(_ name: String) { lock.withLock { commands.append(name) } }

    public func load(_ request: PlayRequest) async throws { record("load:\(request.contextURI.rawValue)") }
    public func resume() async throws { record("resume") }
    public func playHere() async throws { record("playHere") }
    public func pause() async throws { record("pause") }
    public func next() async throws { record("next") }
    public func previous() async throws { record("previous") }
    public func seek(to milliseconds: Int64) async throws { record("seek:\(milliseconds)") }
    public func setVolume(_ value: Double) async throws { record("setVolume:\(value)") }
    public func selectQueueEntry(_ target: QueueTarget) async throws { record("selectQueue:\(target.generation):\(target.rawNextIndex)") }
    public func setShuffle(_ enabled: Bool) async throws { record("setShuffle:\(enabled)") }
    public func setRepeat(_ mode: RepeatMode) async throws { record("setRepeat:\(mode.rawValue)") }
    public func requestRadio(seed: SpotifyURI) async throws -> RadioMix {
        record("radio:\(seed.rawValue)")
        throw RadioFailure.unavailable
    }

}
