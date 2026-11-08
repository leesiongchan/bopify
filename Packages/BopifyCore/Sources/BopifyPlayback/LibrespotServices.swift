import Foundation
import BopifyDomain
import CBopifyCore

/// Metadata transport only; its native session creates no Player, Mixer or Spirc.
protocol SoloistDataServices: Sendable {
    func requestRadio(seed: SpotifyURI) async throws -> RadioMix
    func requestLyrics(for track: SpotifyURI) async throws -> TrackLyrics
    func requestArtistTopTracks(for track: SpotifyURI, artistIndex: Int) async throws -> ArtistTopTracks
    func shutdown() async
}

/// Owns a metadata session with no audio commands or playback-engine conformance.
/// Call `shutdown()` before releasing it: destroying the native runtime blocks,
/// so deinit finishes waiters but deliberately cannot destroy the session.
public final class LibrespotServices: SoloistDataServices, @unchecked Sendable {
    private let bridge: EventBridge
    private let context: UnsafeMutableRawPointer
    private let handle: OpaquePointer
    private let native: LibrespotServiceFFI
    private let lock = NSLock()
    private var contextReleased = false

    public convenience init(accessToken: String, expectedUsername: String) async throws {
        try await self.init(accessToken: accessToken, expectedUsername: expectedUsername, native: .live)
    }

    /// Native login and teardown must stay off the caller's actor.
    @concurrent
    init(accessToken: String, expectedUsername: String, native: LibrespotServiceFFI) async throws {
        guard !expectedUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              expectedUsername.utf8.count <= 256,
              !expectedUsername.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw SoloistPlaybackError.missingAccountID
        }
        // The native login compares this identity before exposing any metadata requests.
        let encoded = try JSONSerialization.data(withJSONObject: [
            "deviceId": "bopify-services", "startup": "coldLaunch", "servicesOnly": true,
            "expectedUsername": expectedUsername,
        ])
        let options = String(decoding: encoded, as: UTF8.self)
        let bridge = EventBridge()
        let context = bridge.retainedContext()
        var code: Int32 = 0
        BopifyLog.playback.info("data services create starting")
        guard let handle = native.create(accessToken, "Bopify services", options, context, &code) else {
            bridge.finish()
            EventBridge.releaseContext(context)
            BopifyLog.playback.error("data services create failed code=\(code, privacy: .public)")
            throw PlayerError(ffiCode: code)
        }
        self.bridge = bridge
        self.context = context
        self.handle = handle
        self.native = native
        BopifyLog.playback.info("data services create succeeded")
    }

    @concurrent
    public func requestRadio(seed: SpotifyURI) async throws -> RadioMix {
        try await bridge.radio(seed: seed) { id in
            try perform("requestRadio") { native.radio(handle, seed.rawValue, id) }
        }
    }

    @concurrent
    public func requestLyrics(for track: SpotifyURI) async throws -> TrackLyrics {
        try await bridge.lyrics(for: track) { id in
            try perform("requestLyrics") { native.lyrics(handle, track.rawValue, id) }
        }
    }

    @concurrent
    public func requestArtistTopTracks(for track: SpotifyURI, artistIndex: Int) async throws -> ArtistTopTracks {
        guard let index = UInt32(exactly: artistIndex) else { throw ArtistTopTracksFailure.unavailable }
        return try await bridge.artistTopTracks(for: track) { id in
            try perform("requestArtistTopTracks") { native.artistTopTracks(handle, track.rawValue, index, id) }
        }
    }

    @concurrent
    public func shutdown() async {
        bridge.finish()
        // Every caller waits for destroy, including those racing the first caller.
        // The callback context can only be released after teardown has returned.
        native.destroy(handle)
        let release = lock.withLock {
            guard !contextReleased else { return false }
            contextReleased = true
            return true
        }
        if release { EventBridge.releaseContext(context) }
        BopifyLog.playback.info("data services shutdown complete")
    }

    private func perform(_ request: String, _ body: () -> Int32) throws {
        let code = body()
        guard code == 0 else {
            BopifyLog.playback.error("data services request failed request=\(request, privacy: .public) code=\(code, privacy: .public)")
            throw PlayerError(ffiCode: code)
        }
    }

    deinit {
        if lock.withLock({ !contextReleased }) {
            BopifyLog.playback.error("data services deallocated without shutdown; native session and callback context leaked")
        }
        bridge.finish()
    }
}

/// The native boundary deliberately contains only session lifecycle and metadata requests.
struct LibrespotServiceFFI: Sendable {
    var create: @Sendable (String, String, String, UnsafeMutableRawPointer, inout Int32) -> OpaquePointer?
    var destroy: @Sendable (OpaquePointer) -> Void
    var radio: @Sendable (OpaquePointer, String, UInt64) -> Int32
    var lyrics: @Sendable (OpaquePointer, String, UInt64) -> Int32
    var artistTopTracks: @Sendable (OpaquePointer, String, UInt32, UInt64) -> Int32

    static let live = LibrespotServiceFFI(
        create: { token, name, options, context, code in
            options.withCString { bopify_engine_create(token, name, $0, bopifyEventTrampoline, context, &code) }
        },
        destroy: { bopify_engine_destroy($0) },
        radio: { handle, uri, id in uri.withCString { bopify_request_radio(handle, $0, id) } },
        lyrics: { handle, uri, id in uri.withCString { bopify_request_lyrics(handle, $0, id) } },
        artistTopTracks: { handle, uri, index, id in uri.withCString { bopify_request_artist_top_tracks(handle, $0, index, id) } }
    )
}
