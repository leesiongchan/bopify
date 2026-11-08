#if DEBUG
import Foundation
import BopifyDomain
import BopifyPlayback

/// Plays a fixed sample queue for previews. Each command answers with playback events,
/// so transport, queue selection and stations stay interactive in the canvas.
nonisolated final class PreviewPlaybackEngine: PreparedPlaybackEngine, @unchecked Sendable {
    let events: AsyncStream<PlaybackEvent>
    private let continuation: AsyncStream<PlaybackEvent>.Continuation
    private let lock = NSLock()
    private let tracks: [Track]
    private var playbackOrder: [Int]
    private var index = 0
    private var generation: UInt64 = 0
    private var positionMs: Int64 = 0
    private var playingSince: Date?

    init(tracks: [Track]) {
        precondition(!tracks.isEmpty, "a preview queue needs a track")
        self.tracks = tracks
        playbackOrder = Array(tracks.indices)
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    func shutdown() async { continuation.finish() }
    func adopt(initialVolume: Double) async throws { try await setVolume(initialVolume) }
    func activateForSetup() async throws { try await playHere() }
    func suspendDataServices() async {}
    func retryDataServices() async {}

    private func emit(_ event: PlaybackEvent) { continuation.yield(event) }

    /// The events of a session restored on `index`, for the player to fold before its first frame.
    func restoredSession(at index: Int, positionMs: Int64, playing: Bool) -> [PlaybackEvent] {
        lock.withLock { playbackOrder = Array(tracks.indices); self.index = index; self.positionMs = positionMs }
        return [.startupResolved(.restored), .volumeChanged(volume: 0.7)] + current(playing: playing)
    }

    func load(_ request: PlayRequest) async throws {
        let selected = request.startTrackURI ?? request.contextURI
        let selectedIndex = tracks.firstIndex { $0.uri == selected } ?? 0
        var order = Array(tracks.indices)
        var position = selectedIndex
        if !request.followingTrackURIs.isEmpty {
            guard tracks[selectedIndex].uri == selected else { throw SoloistPlaybackError.unsupported }
            var seen: Set<SpotifyURI> = [selected]
            order = [selectedIndex]
            for uri in request.followingTrackURIs where seen.insert(uri).inserted {
                guard let next = tracks.firstIndex(where: { $0.uri == uri }) else { throw SoloistPlaybackError.unsupported }
                order.append(next)
            }
            position = 0
        }
        lock.withLock { playbackOrder = order; index = position; positionMs = 0 }
        show(playing: true)
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

    func next() async throws { move(to: lock.withLock { (index + 1) % playbackOrder.count }) }
    func previous() async throws { move(to: lock.withLock { (index + playbackOrder.count - 1) % playbackOrder.count }) }

    func seek(to milliseconds: Int64) async throws {
        lock.withLock {
            positionMs = milliseconds
            if playingSince != nil { playingSince = Date() }
        }
        emit(.seeked(positionMs: milliseconds))
    }

    func setVolume(_ value: Double) async throws { emit(.volumeChanged(volume: value)) }

    func selectQueueEntry(_ target: QueueTarget) async throws {
        move(to: lock.withLock { min(playbackOrder.count - 1, index + 1 + Int(target.rawNextIndex)) })
    }

    func setShuffle(_ enabled: Bool) async throws { emit(.shuffleChanged(enabled)) }
    func setRepeat(_ mode: RepeatMode) async throws { emit(.repeatChanged(mode)) }

    func requestRadio(seed: SpotifyURI) async throws -> RadioMix {
        RadioMix(contextURI: SpotifyURI("spotify:playlist:preview-radio")!, tracks: tracks)
    }

    func requestLyrics(for track: SpotifyURI) async throws -> TrackLyrics { throw LyricFailure.unavailable }

    func requestArtistTopTracks(for track: SpotifyURI, artistIndex: Int) async throws -> ArtistTopTracks {
        throw ArtistTopTracksFailure.unavailable
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
            let entries = playbackOrder.enumerated().map { k, trackIndex in
                QueueEntry(id: "preview-\(trackIndex)", uri: tracks[trackIndex].uri,
                           target: k > index ? QueueTarget(generation: generation, rawNextIndex: UInt32(k - index - 1)) : nil,
                           track: tracks[trackIndex], metadataFailed: false)
            }
            let queue = PlaybackQueue(generation: generation, previous: Array(entries[..<index]),
                                      current: entries[index], next: Array(entries[(index + 1)...]))
            return (queue, tracks[playbackOrder[index]], positionMs)
        }
        return [.availablePlaybackOptions(canShuffle: true, canRepeat: true),
                .queueChanged(queue), .trackChanged(track), playing ? .playing(positionMs: position) : .paused(positionMs: position)]
    }
}
#endif
