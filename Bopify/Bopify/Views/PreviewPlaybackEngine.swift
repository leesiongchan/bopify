#if DEBUG
import Foundation
import BopifyDomain

/// Plays a fixed sample queue for previews. Each command answers with the events librespot would send,
/// so transport, queue selection and stations stay interactive in the canvas.
nonisolated final class PreviewPlaybackEngine: PlaybackEngine, @unchecked Sendable {
    let events: AsyncStream<PlaybackEvent>
    private let continuation: AsyncStream<PlaybackEvent>.Continuation
    private let lock = NSLock()
    private let tracks: [Track]
    private var index = 0
    private var generation: UInt64 = 0
    private var positionMs: Int64 = 0
    private var playingSince: Date?

    init(tracks: [Track]) {
        precondition(!tracks.isEmpty, "a preview queue needs a track")
        self.tracks = tracks
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    private func emit(_ event: PlaybackEvent) { continuation.yield(event) }

    /// The events of a session restored on `index`, for the player to fold before its first frame.
    func restoredSession(at index: Int, positionMs: Int64, playing: Bool) -> [PlaybackEvent] {
        lock.withLock { self.index = index; self.positionMs = positionMs }
        return [.startupResolved(.restored), .volumeChanged(volume: 0.7)] + current(playing: playing)
    }

    func load(_ request: PlayRequest) async throws {
        move(to: tracks.firstIndex { $0.uri == request.startTrackURI } ?? 0)
    }

    func resume() async throws {
        let position = lock.withLock { playingSince = Date(); return positionMs }
        emit(.playing(positionMs: position))
    }

    func playHere() async throws {
        emit(.activeDeviceChanged(isActive: true))
        show(playing: true)
    }

    func pause() async throws {
        let position = lock.withLock {
            positionMs = currentPosition
            playingSince = nil
            return positionMs
        }
        emit(.paused(positionMs: position))
    }

    func next() async throws { move(to: lock.withLock { (index + 1) % tracks.count }) }
    func previous() async throws { move(to: lock.withLock { (index + tracks.count - 1) % tracks.count }) }

    func seek(to milliseconds: Int64) async throws {
        lock.withLock {
            positionMs = milliseconds
            if playingSince != nil { playingSince = Date() }
        }
        emit(.seeked(positionMs: milliseconds))
    }

    func setVolume(_ value: Double) async throws { emit(.volumeChanged(volume: value)) }

    func selectQueueEntry(_ target: QueueTarget) async throws {
        move(to: lock.withLock { min(tracks.count - 1, index + 1 + Int(target.rawNextIndex)) })
    }

    func setShuffle(_ enabled: Bool) async throws { emit(.shuffleChanged(enabled)) }
    func setRepeat(_ mode: RepeatMode) async throws { emit(.repeatChanged(mode)) }

    func requestRadio(seed: SpotifyURI) async throws -> RadioMix {
        RadioMix(contextURI: SpotifyURI("spotify:playlist:preview-radio")!, tracks: tracks)
    }

    /// Call with the lock held.
    private var currentPosition: Int64 {
        positionMs + Int64((playingSince.map { Date().timeIntervalSince($0) } ?? 0) * 1000)
    }

    private func move(to next: Int) {
        lock.withLock { index = next; positionMs = 0 }
        show(playing: true)
    }

    private func show(playing: Bool) { current(playing: playing).forEach(emit) }

    private func current(playing: Bool) -> [PlaybackEvent] {
        let (queue, track, position) = lock.withLock {
            generation += 1
            playingSince = playing ? Date() : nil
            let entries = tracks.indices.map { k in
                QueueEntry(id: "preview-\(k)", uri: tracks[k].uri,
                           target: k > index ? QueueTarget(generation: generation, rawNextIndex: UInt32(k - index - 1)) : nil,
                           track: tracks[k], metadataFailed: false)
            }
            let queue = PlaybackQueue(generation: generation, previous: Array(entries[..<index]),
                                      current: entries[index], next: Array(entries[(index + 1)...]))
            return (queue, tracks[index], positionMs)
        }
        return [.queueChanged(queue), .trackChanged(track), playing ? .playing(positionMs: position) : .paused(positionMs: position)]
    }
}
#endif
