import Foundation
import BopifyDomain
import os

/// Bridges the Rust event callback onto an `AsyncStream`.
///
/// The callback arrives on a Rust runtime thread and can fire before
/// `bopify_engine_create` returns, so the bridge is fully usable the moment
/// it is constructed and never reaches back for the engine handle. It only
/// buffers: the header forbids issuing a command from inside the callback,
/// and handing the event to a stream is what keeps the consumer off that
/// thread.
public final class EventBridge: Sendable {
    public let events: AsyncStream<PlaybackEvent>
    private let continuation: AsyncStream<PlaybackEvent>.Continuation
    private let radioWaiters = OSAllocatedUnfairLock(initialState: RadioWaiters())

    private struct RadioWaiters: Sendable {
        var lastID: UInt64 = 0
        var waiting: [UInt64: CheckedContinuation<RadioMix, any Error>] = [:]
        var finished = false
    }

    private struct Envelope: Decodable {
        let type: String
        let requestID: UInt64?
    }

    public init() {
        var escaped: AsyncStream<PlaybackEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .bufferingNewest(64)) { escaped = $0 }
        self.continuation = escaped
    }

    /// Hands Rust an owning (+1) reference to pass back as `ctx`.
    ///
    /// `ctx` must stay alive until `bopify_engine_destroy` has returned, and
    /// that is the one obligation the Rust side cannot enforce. Retaining
    /// here makes an owner that lets go too early a leak rather than a
    /// use-after-free on a runtime thread.
    public func retainedContext() -> UnsafeMutableRawPointer {
        Unmanaged.passRetained(self).toOpaque()
    }

    /// Sends one radio request and waits for the reply that carries its ID.
    ///
    /// The waiter is registered before `send` runs: the reply can arrive on a
    /// Rust thread before `send` has even returned.
    func radio(_ send: (UInt64) throws -> Void) async throws -> RadioMix {
        let id = radioWaiters.withLock { state in
            state.lastID += 1
            return state.lastID
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let registered = radioWaiters.withLock { state in
                    guard !state.finished else { return false }
                    state.waiting[id] = continuation
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
    private func resolveRadio(_ id: UInt64, with result: Result<RadioMix, any Error>) {
        radioWaiters.withLock { $0.waiting.removeValue(forKey: id) }?.resume(with: result)
    }

    private func deliverRadio(_ data: Data, requestID: UInt64?) {
        guard let reply = try? JSONDecoder().decode(RadioReply.self, from: data) else {
            BopifyLog.playback.error("radio reply decode failed")
            if let requestID { resolveRadio(requestID, with: .failure(RadioFailure.unavailable)) }
            return
        }
        switch reply {
        case let .mix(id, mix): resolveRadio(id, with: .success(mix))
        case let .failed(id, reason): resolveRadio(id, with: .failure(reason))
        }
    }

    /// Balances exactly one `retainedContext()`, and takes that same pointer
    /// so the pairing is visible at the call site.
    ///
    /// Safe only once `bopify_engine_destroy` has returned, or once
    /// `bopify_engine_create` has returned null — which it only does after
    /// dropping the runtime, so no callback can follow either. That ordering
    /// is the one part of this the signature cannot enforce.
    public static func releaseContext(_ ctx: UnsafeMutableRawPointer) {
        Unmanaged<EventBridge>.fromOpaque(ctx).release()
    }

    /// Decodes one event off the Rust runtime thread that delivered it.
    func yield(rawJSON: UnsafeRawBufferPointer) {
        guard let base = rawJSON.baseAddress, !rawJSON.isEmpty else { return }
        let data = Data(bytes: base, count: rawJSON.count)
        // Radio replies answer one caller; the playback stream never sees them.
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
           RadioReply.eventTypes.contains(envelope.type) {
            deliverRadio(data, requestID: envelope.requestID)
            return
        }
        // A malformed payload is a bug in the wire contract, not a user-facing
        // failure. Drop it rather than tearing down playback.
        guard let event = try? JSONDecoder().decode(PlaybackEvent.self, from: data) else {
            // The payload carries the track title and artwork URL, so it is
            // user content and never logged at .public.
            let payload = String(decoding: data, as: UTF8.self)
            BopifyLog.playback.error("event decode failed payload=\(payload, privacy: .private)")
            return
        }
        if case .sessionLost = event { failRadioWaiters() }
        if case .failed(.playbackSessionLost) = event { failRadioWaiters() }
        continuation.yield(event)
    }

    /// Ends the stream for its consumer and fails any radio request still
    /// waiting. Idempotent, and independent of the engine: events yielded
    /// after it are dropped, not delivered.
    public func finish() {
        continuation.finish()
        failRadioWaiters()
    }

    private func failRadioWaiters() {
        let waiting = radioWaiters.withLock { state in
            state.finished = true
            defer { state.waiting = [:] }
            return Array(state.waiting.values)
        }
        for waiter in waiting { waiter.resume(throwing: PlayerError.playbackSessionLost) }
    }

    /// A bridge dropped without an explicit `finish()` would otherwise leave
    /// its consumer awaiting an event that can never arrive.
    deinit { continuation.finish() }
}

/// Matches the callback in `bopify_core.h` exactly. Must be a top-level
/// function: a C function pointer cannot capture, so the bridge arrives as
/// `ctx`.
///
/// Runs on a Rust runtime thread, so it must not issue a command on the
/// engine: per the header that can deadlock against a concurrent destroy.
func bopifyEventTrampoline(
    _ json: UnsafePointer<UInt8>?,
    _ len: UInt,
    _ ctx: UnsafeMutableRawPointer?
) {
    guard let json, let ctx else { return }
    let bridge = Unmanaged<EventBridge>.fromOpaque(ctx).takeUnretainedValue()
    bridge.yield(rawJSON: UnsafeRawBufferPointer(start: json, count: Int(len)))
}
