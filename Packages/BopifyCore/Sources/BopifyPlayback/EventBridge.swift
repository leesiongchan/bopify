import Foundation
import BopifyDomain
import os

/// Usable from construction and never reaches for the engine handle, because the callback can fire on a Rust thread
/// before `bopify_engine_create` returns. It only buffers, since the header forbids issuing commands from the callback.
public final class EventBridge: Sendable {
    public let events: AsyncStream<PlaybackEvent>
    private let continuation: AsyncStream<PlaybackEvent>.Continuation
    private let radioWaiters = OSAllocatedUnfairLock(initialState: RadioWaiters())
    private let lyricWaiters = OSAllocatedUnfairLock(initialState: LyricWaiters())
    private let artistWaiters = OSAllocatedUnfairLock(initialState: ArtistWaiters())
    private let lyricSleep: @Sendable (Duration) async throws -> Void
    private let artistSleep: @Sendable (Duration) async throws -> Void
    private let radioSleep: @Sendable (Duration) async throws -> Void

    /// How long a reply waiter lives. It must exceed Rust's `REPLY_DEADLINE` (30 s), so
    /// the engine's own failure reply arrives first and this only catches a lost reply.
    static let replyWatchdog: Duration = .seconds(35)

    private struct ArtistWaiter: Sendable {
        let track: SpotifyURI
        let continuation: CheckedContinuation<ArtistTopTracks, any Error>
        let watchdog: Task<Void, Never>
    }

    private struct ArtistWaiters: Sendable {
        var lastID: UInt64 = 0
        var waiting: [UInt64: ArtistWaiter] = [:]
        var finished = false
    }

    private struct LyricWaiter: Sendable {
        let track: SpotifyURI
        let continuation: CheckedContinuation<TrackLyrics, any Error>
        let watchdog: Task<Void, Never>
    }

    private struct LyricWaiters: Sendable {
        var lastID: UInt64 = 0
        var waiting: [UInt64: LyricWaiter] = [:]
        var finished = false
    }

    private struct RadioWaiter: Sendable {
        let seed: SpotifyURI
        let continuation: CheckedContinuation<RadioMix, any Error>
        let watchdog: Task<Void, Never>
    }

    private struct RadioWaiters: Sendable {
        var lastID: UInt64 = 0
        var waiting: [UInt64: RadioWaiter] = [:]
        var finished = false
    }

    private struct Envelope: Decodable {
        let type: String
        let requestID: UInt64?
    }

    // A damaged ID must still route replies away from playback's payload logging.
    private struct ReplyEnvelope: Decodable {
        let type: String
        let requestID: UInt64?
        private enum CodingKeys: String, CodingKey { case type, requestID }
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try c.decode(String.self, forKey: .type)
            requestID = try? c.decode(UInt64.self, forKey: .requestID)
        }
    }

    public convenience init() {
        self.init(lyricSleep: { try await Task.sleep(for: $0) })
    }

    init(lyricSleep: @escaping @Sendable (Duration) async throws -> Void,
         artistSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         radioSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.lyricSleep = lyricSleep
        self.artistSleep = artistSleep
        self.radioSleep = radioSleep
        var escaped: AsyncStream<PlaybackEvent>.Continuation!
        // Queue metadata bursts must not evict readiness or playback transitions.
        self.events = AsyncStream(bufferingPolicy: .unbounded) { escaped = $0 }
        self.continuation = escaped
    }

    /// Hands Rust an owning (+1) reference as `ctx`, which must outlive `bopify_engine_destroy`. Retaining makes an
    /// owner that lets go too early leak instead of causing a use-after-free on a runtime thread.
    public func retainedContext() -> UnsafeMutableRawPointer {
        Unmanaged.passRetained(self).toOpaque()
    }

    /// Sends one radio request and waits for the reply that carries its ID.
    ///
    /// The waiter is registered before `send` runs: the reply can arrive on a
    /// Rust thread before `send` has even returned.
    func radio(seed: SpotifyURI, _ send: (UInt64) throws -> Void) async throws -> RadioMix {
        let id = radioWaiters.withLock { state in
            state.lastID += 1
            return state.lastID
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let registered = radioWaiters.withLock { state in
                    guard !state.finished else { return false }
                    let sleep = radioSleep
                    // Attach the timer before send: even a synchronous callback can cancel it.
                    let watchdog = Task { [weak self] in
                        do { try await sleep(Self.replyWatchdog) } catch { return }
                        guard !Task.isCancelled else { return }
                        self?.resolveRadio(id, with: .failure(RadioFailure.network))
                    }
                    state.waiting[id] = RadioWaiter(seed: seed, continuation: continuation, watchdog: watchdog)
                    return true
                }
                guard registered else { return continuation.resume(throwing: PlayerError.playbackSessionLost) }
                if Task.isCancelled { return resolveRadio(id, with: .failure(CancellationError())) }
                do { try send(id) } catch { resolveRadio(id, with: .failure(error)) }
            }
        } onCancel: {
            resolveRadio(id, with: .failure(CancellationError()))
        }
    }

    /// Resumes a waiter at most once; a reply for an ID nobody waits on is dropped.
    private func resolveRadio(_ id: UInt64, seed: SpotifyURI? = nil, with result: Result<RadioMix, any Error>) {
        guard let waiter = radioWaiters.withLock({ $0.waiting.removeValue(forKey: id) }) else { return }
        waiter.watchdog.cancel()
        guard seed.map({ $0 != waiter.seed }) != true else {
            BopifyLog.playback.error("radio reply seed mismatch id=\(id, privacy: .public)")
            return waiter.continuation.resume(throwing: RadioFailure.unavailable)
        }
        waiter.continuation.resume(with: result)
    }

    private func deliverRadio(_ data: Data, requestID: UInt64?) {
        guard let reply = try? JSONDecoder().decode(RadioReply.self, from: data) else {
            BopifyLog.playback.error("radio reply decode failed")
            if let requestID { resolveRadio(requestID, with: .failure(RadioFailure.unavailable)) }
            return
        }
        switch reply {
        case let .mix(id, seed, mix): resolveRadio(id, seed: seed, with: .success(mix))
        case let .failed(id, seed, reason): resolveRadio(id, seed: seed, with: .failure(reason))
        }
    }

    func lyrics(for track: SpotifyURI, _ send: (UInt64) throws -> Void) async throws -> TrackLyrics {
        let id = lyricWaiters.withLock { state in
            state.lastID += 1
            return state.lastID
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let registered = lyricWaiters.withLock { state in
                    guard !state.finished else { return false }
                    let sleep = lyricSleep
                    // Attach the timer before send: even a synchronous callback can cancel it.
                    let watchdog = Task { [weak self] in
                        do { try await sleep(Self.replyWatchdog) } catch { return }
                        guard !Task.isCancelled else { return }
                        self?.resolveLyrics(id, with: .failure(LyricFailure.network))
                    }
                    state.waiting[id] = LyricWaiter(track: track, continuation: continuation, watchdog: watchdog)
                    return true
                }
                guard registered else { return continuation.resume(throwing: PlayerError.playbackSessionLost) }
                if Task.isCancelled { return resolveLyrics(id, with: .failure(CancellationError())) }
                BopifyLog.playback.debug("lyrics request queued id=\(id, privacy: .public)")
                do { try send(id) } catch { resolveLyrics(id, with: .failure(error)) }
            }
        } onCancel: {
            resolveLyrics(id, with: .failure(CancellationError()))
        }
    }

    private func resolveLyrics(_ id: UInt64, track: SpotifyURI? = nil, with result: Result<TrackLyrics, any Error>) {
        guard let waiter = lyricWaiters.withLock({ $0.waiting.removeValue(forKey: id) }) else { return }
        waiter.watchdog.cancel()
        let result = track.map { $0 != waiter.track } == true
            ? .failure(LyricFailure.unavailable) : result
        let outcome: String
        switch result {
        case .success: outcome = "success"
        case let .failure(reason as LyricFailure): outcome = reason.rawValue
        case .failure(is CancellationError): outcome = "cancelled"
        case .failure: outcome = "engineFailure"
        }
        BopifyLog.playback.debug("lyrics request completed id=\(id, privacy: .public) outcome=\(outcome, privacy: .public)")
        waiter.continuation.resume(with: result)
    }

    private func deliverLyrics(_ data: Data, requestID: UInt64?) {
        guard let reply = try? JSONDecoder().decode(LyricReply.self, from: data) else {
            BopifyLog.playback.error("lyrics reply decode failed")
            if let requestID { resolveLyrics(requestID, with: .failure(LyricFailure.unavailable)) }
            return
        }
        switch reply {
        case let .lyrics(id, lyrics): resolveLyrics(id, track: reply.trackURI, with: .success(lyrics))
        case let .failed(id, track, reason): resolveLyrics(id, track: track, with: .failure(reason))
        }
    }

    func artistTopTracks(for track: SpotifyURI, _ send: (UInt64) throws -> Void) async throws -> ArtistTopTracks {
        let id = artistWaiters.withLock { state in state.lastID += 1; return state.lastID }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let registered = artistWaiters.withLock { state in
                    guard !state.finished else { return false }
                    let sleep = artistSleep
                    let watchdog = Task { [weak self] in
                        do { try await sleep(Self.replyWatchdog) } catch { return }
                        guard !Task.isCancelled else { return }
                        self?.resolveArtist(id, with: .failure(ArtistTopTracksFailure.network))
                    }
                    state.waiting[id] = ArtistWaiter(track: track, continuation: continuation, watchdog: watchdog)
                    return true
                }
                guard registered else { return continuation.resume(throwing: PlayerError.playbackSessionLost) }
                if Task.isCancelled { return resolveArtist(id, with: .failure(CancellationError())) }
                do { try send(id) } catch { resolveArtist(id, with: .failure(error)) }
            }
        } onCancel: {
            resolveArtist(id, with: .failure(CancellationError()))
        }
    }

    private func resolveArtist(_ id: UInt64, track: SpotifyURI? = nil, with result: Result<ArtistTopTracks, any Error>) {
        guard let waiter = artistWaiters.withLock({ $0.waiting.removeValue(forKey: id) }) else { return }
        waiter.watchdog.cancel()
        waiter.continuation.resume(with: track.map { $0 != waiter.track } == true
            ? .failure(ArtistTopTracksFailure.unavailable) : result)
    }

    private func deliverArtist(_ data: Data, requestID: UInt64?) {
        guard let reply = try? JSONDecoder().decode(ArtistTopTracksReply.self, from: data) else {
            BopifyLog.playback.error("artist songs reply decode failed")
            if let requestID { resolveArtist(requestID, with: .failure(ArtistTopTracksFailure.unavailable)) }
            return
        }
        switch reply {
        case let .tracks(id, songs): resolveArtist(id, track: songs.trackURI, with: .success(songs))
        case let .failed(id, track, reason): resolveArtist(id, track: track, with: .failure(reason))
        }
    }

    /// Balances exactly one `retainedContext()`, taking the same pointer so the pairing is visible at the call site.
    /// Call it only after `bopify_engine_destroy` returns or `bopify_engine_create` returns null, as no callback can follow either.
    public static func releaseContext(_ ctx: UnsafeMutableRawPointer) {
        Unmanaged<EventBridge>.fromOpaque(ctx).release()
    }

    /// Decodes one event off the Rust runtime thread that delivered it.
    func yield(rawJSON: UnsafeRawBufferPointer) {
        guard let base = rawJSON.baseAddress, !rawJSON.isEmpty else { return }
        let data = Data(bytes: base, count: rawJSON.count)
        let envelope = try? JSONDecoder().decode(ReplyEnvelope.self, from: data)
        if let envelope {
            if ArtistTopTracksReply.eventTypes.contains(envelope.type) {
                deliverArtist(data, requestID: envelope.requestID)
                return
            }
            if LyricReply.eventTypes.contains(envelope.type) {
                deliverLyrics(data, requestID: envelope.requestID)
                return
            }
            // Radio replies answer one caller; the playback stream never sees them.
            if RadioReply.eventTypes.contains(envelope.type),
               let radio = try? JSONDecoder().decode(Envelope.self, from: data) {
                deliverRadio(data, requestID: radio.requestID)
                return
            }
        }
        // A malformed payload is a bug in the wire contract, not a user-facing
        // failure. Drop it rather than tearing down playback.
        let event: PlaybackEvent
        do {
            event = try JSONDecoder().decode(PlaybackEvent.self, from: data)
        } catch {
            // The payload carries the track title and artwork URL, so it is
            // user content and never logged at .public. Type and field names are not.
            let payload = String(decoding: data, as: UTF8.self)
            let type = envelope?.type ?? "unreadable"
            let field = (error as? DecodingError)?.fieldPath ?? "unknown"
            BopifyLog.playback.error("event decode failed type=\(type, privacy: .public) field=\(field, privacy: .public) payload=\(payload, privacy: .private)")
            return
        }
        if case .sessionLost = event { failRadioWaiters(); failLyricWaiters(); failArtistWaiters() }
        continuation.yield(event)
    }

    /// Ends the stream for its consumer and fails any metadata request still
    /// waiting. Idempotent, and independent of the engine: events yielded
    /// after it are dropped, not delivered.
    public func finish() {
        continuation.finish()
        failRadioWaiters()
        failLyricWaiters()
        failArtistWaiters()
    }

    private func failRadioWaiters() {
        let waiting = radioWaiters.withLock { state in
            state.finished = true
            defer { state.waiting = [:] }
            return Array(state.waiting.values)
        }
        for waiter in waiting {
            waiter.watchdog.cancel()
            waiter.continuation.resume(throwing: PlayerError.playbackSessionLost)
        }
    }

    private func failLyricWaiters() {
        let waiting = lyricWaiters.withLock { state in
            state.finished = true
            defer { state.waiting = [:] }
            return Array(state.waiting.values)
        }
        for waiter in waiting {
            waiter.watchdog.cancel()
            waiter.continuation.resume(throwing: PlayerError.playbackSessionLost)
        }
    }

    private func failArtistWaiters() {
        let waiting = artistWaiters.withLock { state in
            state.finished = true
            defer { state.waiting = [:] }
            return Array(state.waiting.values)
        }
        for waiter in waiting {
            waiter.watchdog.cancel()
            waiter.continuation.resume(throwing: PlayerError.playbackSessionLost)
        }
    }

    /// A bridge dropped without an explicit `finish()` would otherwise leave
    /// its consumer awaiting an event that can never arrive.
    deinit { continuation.finish() }
}

/// Top-level because a C function pointer cannot capture, so the bridge arrives as `ctx`.
/// It runs on a Rust runtime thread and must not issue engine commands, which can deadlock against a concurrent destroy.
func bopifyEventTrampoline(
    _ json: UnsafePointer<UInt8>?,
    _ len: UInt,
    _ ctx: UnsafeMutableRawPointer?
) {
    guard let json, let ctx else { return }
    let bridge = Unmanaged<EventBridge>.fromOpaque(ctx).takeUnretainedValue()
    bridge.yield(rawJSON: UnsafeRawBufferPointer(start: json, count: Int(len)))
}

extension DecodingError {
    /// Keys name fields and never carry values, so the path is safe to log publicly.
    var fieldPath: String {
        let keys: [any CodingKey] = switch self {
        case let .keyNotFound(key, context): context.codingPath + [key]
        case let .typeMismatch(_, context), let .valueNotFound(_, context), let .dataCorrupted(context): context.codingPath
        @unknown default: []
        }
        return keys.isEmpty ? "root" : keys.map(\.stringValue).joined(separator: ".")
    }
}
