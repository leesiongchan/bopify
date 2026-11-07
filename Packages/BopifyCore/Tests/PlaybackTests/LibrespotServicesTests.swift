import Foundation
import Testing
import BopifyDomain
@testable import BopifyPlayback

@Suite("Librespot data services", .timeLimit(.minutes(1)))
struct LibrespotServicesTests {
    private let track = SpotifyURI("spotify:track:11dFghVXANMlKmJXsNCbNl")!

    @Test func creationAlwaysRequestsADataOnlySession() async throws {
        let native = ServiceFFIFixture()
        let services = try await LibrespotServices(accessToken: "fixture-token", native: native.functions)
        let options = try #require(native.options)
        let object = try #require(JSONSerialization.jsonObject(with: Data(options.utf8)) as? [String: Any])
        #expect(object["servicesOnly"] as? Bool == true)
        #expect(native.token == "fixture-token")
        await services.shutdown()
    }

    @Test func failedAuthenticationReleasesTheCallbackContext() async {
        let native = ServiceFFIFixture(createError: -3)
        await #expect(throws: PlayerError.authExpired) {
            _ = try await LibrespotServices(accessToken: "fixture-token", native: native.functions)
        }
        #expect(native.bridge == nil)
        #expect(native.destroyCount == 0)
    }

    @Test func metadataRepliesReturnToTheirRequestingService() async throws {
        let native = ServiceFFIFixture()
        let services = try await LibrespotServices(accessToken: "fixture-token", native: native.functions)
        let lyrics = try await services.requestLyrics(for: track)
        let radio = try await services.requestRadio(seed: track)
        let artist = try await services.requestArtistTopTracks(for: track, artistIndex: 2)
        #expect(lyrics.trackURI == track)
        #expect(lyrics.lines == [TrackLyricLine(text: "A quiet street", startTimeMs: 1000)])
        #expect(radio.contextURI.rawValue == "spotify:playlist:fixture")
        #expect(artist.trackURI == track)
        #expect(artist.tracks.isEmpty)
        #expect(native.requests == ["lyrics:\(track.rawValue)", "radio:\(track.rawValue)", "artist:\(track.rawValue):2"])
        await services.shutdown()
    }

    @Test func nativeRequestRejectionUsesTheSharedErrorTaxonomy() async throws {
        let native = ServiceFFIFixture(requestError: -5)
        let services = try await LibrespotServices(accessToken: "fixture-token", native: native.functions)
        await #expect(throws: PlayerError.networkUnavailable) { _ = try await services.requestLyrics(for: track) }
        await #expect(throws: PlayerError.networkUnavailable) { _ = try await services.requestRadio(seed: track) }
        await #expect(throws: PlayerError.networkUnavailable) {
            _ = try await services.requestArtistTopTracks(for: track, artistIndex: 0)
        }
        await services.shutdown()
    }

    @Test(arguments: [-1, Int.max])
    func invalidArtistIndexNeverReachesNativeServices(index: Int) async throws {
        let native = ServiceFFIFixture()
        let services = try await LibrespotServices(accessToken: "fixture-token", native: native.functions)
        await #expect(throws: ArtistTopTracksFailure.unavailable) {
            _ = try await services.requestArtistTopTracks(for: track, artistIndex: index)
        }
        #expect(native.requests.isEmpty)
        await services.shutdown()
    }

    @Test func shutdownFailsPendingRequestsAndPreventsFurtherDispatch() async throws {
        let native = ServiceFFIFixture(replies: false)
        let services = try await LibrespotServices(accessToken: "fixture-token", native: native.functions)
        let request = Task { try await services.requestLyrics(for: track) }
        for await _ in native.dispatched { break }
        await services.shutdown()
        await #expect(throws: PlayerError.playbackSessionLost) { _ = try await request.value }
        await #expect(throws: PlayerError.playbackSessionLost) { _ = try await services.requestRadio(seed: track) }
        #expect(native.requests == ["lyrics:\(track.rawValue)"])
    }

    @Test func concurrentShutdownReleasesTheContextExactlyOnceAfterDestroy() async throws {
        let native = ServiceFFIFixture()
        var services: LibrespotServices? = try await LibrespotServices(accessToken: "fixture-token", native: native.functions)
        try #require(native.bridge != nil)
        if let current = services {
            async let first: Void = current.shutdown()
            async let second: Void = current.shutdown()
            _ = await (first, second)
        }
        #expect(native.destroyCount == 2)
        #expect(native.contextAliveDuringDestroy)
        services = nil
        #expect(native.bridge == nil)
    }
}

/// Replaces only the native ABI, which otherwise authenticates over the network.
private final class ServiceFFIFixture: @unchecked Sendable {
    private let lock = NSLock()
    private let createError: Int32
    private let requestError: Int32
    private let replies: Bool
    private var context: UnsafeMutableRawPointer?
    private var storedOptions: String?
    private var storedToken: String?
    private var storedRequests: [String] = []
    private var destroys = 0
    private var aliveDuringDestroy = true
    private weak var storedBridge: EventBridge?
    let dispatched: AsyncStream<Void>
    private let sent: AsyncStream<Void>.Continuation

    init(createError: Int32 = 0, requestError: Int32 = 0, replies: Bool = true) {
        self.createError = createError
        self.requestError = requestError
        self.replies = replies
        (dispatched, sent) = AsyncStream.makeStream()
    }

    var options: String? { lock.withLock { storedOptions } }
    var token: String? { lock.withLock { storedToken } }
    var requests: [String] { lock.withLock { storedRequests } }
    var destroyCount: Int { lock.withLock { destroys } }
    var contextAliveDuringDestroy: Bool { lock.withLock { aliveDuringDestroy } }
    var bridge: EventBridge? { lock.withLock { storedBridge } }

    var functions: LibrespotServiceFFI {
        LibrespotServiceFFI(
            create: { token, _, options, context, error in
                self.lock.withLock {
                    self.context = context
                    self.storedToken = token
                    self.storedOptions = options
                    self.storedBridge = Unmanaged<EventBridge>.fromOpaque(context).takeUnretainedValue()
                }
                error = self.createError
                return self.createError == 0 ? OpaquePointer(bitPattern: 1) : nil
            },
            destroy: { _ in
                self.lock.withLock {
                    self.destroys += 1
                    self.aliveDuringDestroy = self.aliveDuringDestroy && self.storedBridge != nil
                }
            },
            radio: { _, uri, id in
                self.request("radio:\(uri)", reply: #"{"type":"radio","requestID":\#(id),"seedURI":"\#(uri)","contextURI":"spotify:playlist:fixture","tracks":[]}"#)
            },
            lyrics: { _, uri, id in
                self.request("lyrics:\(uri)", reply: #"{"type":"lyrics","requestID":\#(id),"trackURI":"\#(uri)","synchronization":"lineSynced","lines":[{"text":"A quiet street","startTimeMs":1000}],"provider":"fixture","providerDisplayName":"Fixture provider","isRightToLeft":false}"#)
            },
            artistTopTracks: { _, uri, index, id in
                self.request("artist:\(uri):\(index)", reply: #"{"type":"artistTopTracks","requestID":\#(id),"trackURI":"\#(uri)","tracks":[]}"#)
            }
        )
    }

    private func request(_ request: String, reply: String) -> Int32 {
        lock.withLock { storedRequests.append(request) }
        sent.yield(())
        guard requestError == 0 else { return requestError }
        if replies, let context = lock.withLock({ context }) {
            Array(reply.utf8).withUnsafeBufferPointer { bytes in
                bopifyEventTrampoline(bytes.baseAddress, UInt(bytes.count), context)
            }
        }
        return 0
    }
}
