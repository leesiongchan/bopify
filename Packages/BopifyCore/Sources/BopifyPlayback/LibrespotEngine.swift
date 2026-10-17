import Foundation
import BopifyDomain
import CBopifyCore

/// The real engine: owns the Rust handle, the event bridge, and the one
/// lifetime obligation Rust cannot enforce.
///
/// Teardown is explicit, `shutdown()`, and never happens in `deinit`:
/// `bopify_engine_destroy` blocks on the Rust runtime join and then on
/// librespot's audio thread, while `deinit` runs wherever the last reference
/// is dropped — including the main actor. An engine dropped without
/// `shutdown()` therefore leaks the runtime and the event context rather than
/// freeing them from the wrong thread; that trade is why `EventBridge` hands
/// out a retained context in the first place.
///
/// A token refresh is a destroy-and-recreate, not an update:
/// `bopify_update_token` always reports `SessionLost` because librespot
/// cannot swap credentials in place. Call `shutdown()` and build a new
/// `LibrespotEngine`; the old handle stays safe to call and answers every
/// command with `.playbackSessionLost`.
///
/// `@unchecked Sendable`: the two pointers are immutable after `init`, Rust
/// synchronises every entry point internally, and the only mutable state
/// here — the release claim — is lock-guarded.
public final class LibrespotEngine: ManagedPlaybackEngine, @unchecked Sendable {
    public var events: AsyncStream<PlaybackEvent> { bridge.events }

    private let bridge: EventBridge
    /// The pointer `retainedContext()` took a +1 on. Kept alongside the
    /// bridge because the balancing release takes the pointer, not the object.
    private let ctx: UnsafeMutableRawPointer
    private let handle: OpaquePointer
    private let lock = NSLock()
    private var contextReleased = false

    /// Blocks for the whole network login, so it runs on the global executor
    /// rather than the caller's actor.
    @concurrent
    public init(accessToken: String, deviceName: String, configuration: PlaybackEngineConfiguration? = nil) async throws {
        let options = try configuration.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        let bridge = EventBridge()
        // The +1 is taken before the pointer can reach Rust: the callback may
        // fire during login, before this call returns.
        let ctx = bridge.retainedContext()
        var code: Int32 = 0
        BopifyLog.playback.info("engine create starting")
        let created: OpaquePointer?
        if let options {
            created = options.withCString { bopify_engine_create_with_options(accessToken, deviceName, $0, bopifyEventTrampoline, ctx, &code) }
        } else {
            created = bopify_engine_create(accessToken, deviceName, bopifyEventTrampoline, ctx, &code)
        }
        guard let handle = created else {
            // A null return means `Engine::new` failed, and it only fails
            // after its `Runtime` local has been dropped — which joins every
            // worker thread — so no callback has fired and none can. The +1
            // is safe to give back here, and this is the only release that
            // does not follow a destroy.
            bridge.finish()
            EventBridge.releaseContext(ctx)
            let error = PlayerError(ffiCode: code)
            BopifyLog.playback.error("engine create failed code=\(code, privacy: .public) error=\(String(describing: error), privacy: .public)")
            throw error
        }
        self.bridge = bridge
        self.ctx = ctx
        self.handle = handle
        BopifyLog.playback.info("engine create succeeded")
    }

    /// Ends the event stream and tears the session down. Blocking, idempotent,
    /// and safe to call while commands are in flight.
    @concurrent
    public func shutdown() async {
        BopifyLog.playback.info("engine shutdown starting")
        // Events emitted during the multi-second teardown have no consumer
        // worth waking, and a yield after `finish()` is dropped.
        bridge.finish()
        // Destroy is idempotent and *every* caller waits for the teardown, not
        // just the one that won the race, so releasing after any destroy
        // returns is safe. Claiming the release first and returning early
        // would not be: the loser would hand back the context while the
        // winner was still inside the runtime drop.
        bopify_engine_destroy(handle)
        if claimContextRelease() {
            EventBridge.releaseContext(ctx)
        }
        BopifyLog.playback.info("engine shutdown complete")
    }

    /// Exactly one caller gets `true`, and only ever after its own
    /// `bopify_engine_destroy` has returned.
    private func claimContextRelease() -> Bool {
        lock.withLock {
            guard !contextReleased else { return false }
            contextReleased = true
            return true
        }
    }

    deinit {
        // Deliberately no `bopify_engine_destroy`: see the type's doc comment.
        if lock.withLock({ !contextReleased }) {
            BopifyLog.playback.error("engine deallocated without shutdown; the Rust session and event context are leaked")
        }
        // The context's +1 keeps the bridge alive even now, so the bridge's own
        // deinit cannot end the stream. Without this a consumer would await an
        // event that can never arrive.
        bridge.finish()
    }

    /// Turns a command's return code into the domain's error taxonomy.
    /// Success only means "enqueued": the effect arrives as an event.
    private func perform(_ command: String, _ body: () -> Int32) throws {
        let code = body()
        guard code == 0 else {
            let error = PlayerError(ffiCode: code)
            BopifyLog.playback.error("command failed command=\(command, privacy: .public) code=\(code, privacy: .public)")
            throw error
        }
    }

    // Every command is `@concurrent` because a command can block: Rust reads
    // the `alive` flag before taking the read lock, so one that passes that
    // check just as `bopify_engine_destroy` takes the write lock waits out the
    // whole teardown. None of them may issue from the event callback.
    // Logged under the domain's name, not the C function's, so a log grep
    // matches PlayerModel's line for the same action; the Rust side logs
    // `ffi: bopify_play` for the other half.
    @concurrent public func resume() async throws { try perform("resume") { bopify_play(handle) } }
    @concurrent public func playHere() async throws { try perform("playHere") { bopify_play_here(handle) } }
    @concurrent public func pause() async throws { try perform("pause") { bopify_pause(handle) } }
    @concurrent public func next() async throws { try perform("next") { bopify_next(handle) } }
    @concurrent public func previous() async throws { try perform("previous") { bopify_previous(handle) } }

    @concurrent
    public func seek(to milliseconds: Int64) async throws {
        try perform("seek") { bopify_seek(handle, UInt32(clamping: milliseconds)) }
    }

    @concurrent
    public func setVolume(_ value: Double) async throws {
        try perform("setVolume") { bopify_set_volume(handle, Self.scaledVolume(value)) }
    }

    @concurrent
    public func selectQueueEntry(_ target: QueueTarget) async throws {
        try perform("selectQueue") { bopify_select_queue(handle, target.generation, target.rawNextIndex) }
    }

    @concurrent
    public func setShuffle(_ enabled: Bool) async throws {
        try perform("setShuffle") { bopify_set_shuffle(handle, enabled) }
    }

    @concurrent
    public func setRepeat(_ mode: RepeatMode) async throws {
        let raw: UInt8 = switch mode { case .off: 0; case .context: 1; case .track: 2 }
        try perform("setRepeat") { bopify_set_repeat(handle, raw) }
    }

    @concurrent
    public func load(_ request: PlayRequest) async throws {
        let context = request.contextURI.rawValue
        let startTrack = request.startTrackURI?.rawValue
        let position = UInt32(clamping: request.startPositionMs)
        try perform("load") {
            // Both borrows only have to last the call, which is exactly what
            // `withCString` guarantees.
            context.withCString { contextURI in
                guard let startTrack else {
                    return bopify_load(handle, contextURI, nil, position)
                }
                return startTrack.withCString { startURI in
                    bopify_load(handle, contextURI, startURI, position)
                }
            }
        }
    }

    @concurrent
    public func requestRadio(seed: SpotifyURI) async throws -> RadioMix {
        let raw = seed.rawValue
        return try await bridge.radio { id in
            try perform("requestRadio") { raw.withCString { bopify_request_radio(handle, $0, id) } }
        }
    }

    @concurrent
    public func requestLyrics(for track: SpotifyURI) async throws -> TrackLyrics {
        let raw = track.rawValue
        return try await bridge.lyrics(for: track) { id in
            try perform("requestLyrics") { raw.withCString { bopify_request_lyrics(handle, $0, id) } }
        }
    }

    /// librespot's volume is on the `u16::MAX` scale, and the event decoder
    /// divides by that same constant, so a round trip is stable.
    ///
    /// NaN is folded to silence rather than clamped: `min(1, .nan)` returns 1,
    /// so the obvious clamp would answer a malformed value with full volume.
    static func scaledVolume(_ value: Double) -> UInt16 {
        guard !value.isNaN else { return 0 }
        return UInt16((max(0, min(1, value)) * Double(UInt16.max)).rounded())
    }
}
