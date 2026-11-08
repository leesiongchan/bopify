import Foundation
import Testing
import BopifyDomain
@testable import BopifyPlayback

@Suite("Lyrics provider recovery", .serialized)
struct LyricsResolverTests {
    private let track = Track(uri: SpotifyURI("spotify:track:lyrics-fixture")!, title: "Window Seat",
        artists: [ArtistSummary(name: "Soft Weather")], albumTitle: "Quiet Room", artwork: nil, durationMs: 240_000)

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LyricHTTPFixture.self]
        return URLSession(configuration: configuration)
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lyrics-resolver-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func lyric(_ text: String = "Spotify words") -> TrackLyrics {
        TrackLyrics(trackURI: track.uri, synchronization: .unsynced,
            lines: [TrackLyricLine(text: text, startTimeMs: nil)], provider: "spotify", providerDisplayName: "Spotify", isRightToLeft: false)
    }
    private func record(title: String = "Window Seat", artist: String = "Soft Weather", duration: Double = 240,
                        plain: String = "Library words", synced: String? = nil) -> [String: Any] {
        var result: [String: Any] = ["trackName": title, "artistName": artist, "albumName": "Quiet Room", "duration": duration,
                                   "instrumental": false, "plainLyrics": plain]
        if let synced { result["syncedLyrics"] = synced }
        return result
    }

    @Test func spotifySuccessIsReusedFromPersistentCacheWithoutNetworkOrCredentials() async throws {
        LyricHTTPFixture.reset([])
        let cache = try directory(); defer { try? FileManager.default.removeItem(at: cache) }
        let expected = lyric()
        let first = LyricsResolver(cacheDirectory: cache, session: session())
        #expect(try await first.request(for: track) { _ in expected } == expected)
        let second = LyricsResolver(cacheDirectory: cache, session: session())
        #expect(try await second.request(for: track) { _ in throw LyricFailure.unavailable } == expected)
        #expect(LyricHTTPFixture.requests.isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: cache.path)
        #expect(names.count == 1 && !names[0].contains("lyrics-fixture") && !names[0].contains("Window"))
    }

    @Test func spotifyFailureUsesAnonymousExactLookupAndKeepsAttribution() async throws {
        LyricHTTPFixture.reset([.json(record(synced: "[00:01.00]First line\n[00:02.50]Second line"))])
        let resolver = LyricsResolver(cacheDirectory: nil, session: session())
        let result = try await resolver.request(for: track) { _ in throw LyricFailure.unavailable }
        #expect(result.trackURI == track.uri && result.provider == "lrclib" && result.providerDisplayName == "LRCLIB")
        #expect(result.synchronization == .lineSynced)
        #expect(result.lines.map(\.startTimeMs) == [1000, 2500])
        let request = try #require(LyricHTTPFixture.requests.first)
        #expect(request.url?.host == "lrclib.net" && request.url?.path == "/api/get")
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(query.contains(URLQueryItem(name: "duration", value: "240")))
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.contains("Bopify") == true)
    }

    @Test func searchRejectsAnotherArtistAndRecordingVersion() async throws {
        LyricHTTPFixture.reset([.status(404), .json([
            record(title: "Window Seat (Live)", duration: 240), record(artist: "Another Artist"),
            record(duration: 280), record(duration: 241, plain: "Correct recording")
        ])])
        let resolver = LyricsResolver(cacheDirectory: nil, session: session())
        let result = try await resolver.request(for: track) { _ in throw LyricFailure.noLyrics }
        #expect(result.lines.map(\.text) == ["Correct recording"])
        #expect(LyricHTTPFixture.requests.map { $0.url!.path } == ["/api/get", "/api/search"])
    }

    @Test func anUnrelatedExactResponseCannotDisplayWrongLyrics() async throws {
        LyricHTTPFixture.reset([.json(record(artist: "Somebody Else")), .json([])])
        let resolver = LyricsResolver(cacheDirectory: nil, session: session())
        await #expect(throws: LyricFailure.noLyrics) { _ = try await resolver.request(for: track) { _ in throw LyricFailure.noLyrics } }
    }

    @Test func malformedTimingUsesPlainWordsInsteadOfInventingTimes() async throws {
        LyricHTTPFixture.reset([.json(record(plain: "Honest plain words", synced: "[00:broken]Wrong time"))])
        let resolver = LyricsResolver(cacheDirectory: nil, session: session())
        let result = try await resolver.request(for: track) { _ in throw LyricFailure.unavailable }
        #expect(result.synchronization == .unsynced && result.lines.map(\.text) == ["Honest plain words"])
    }

    @Test(arguments: [false, true])
    func timestampsInThePlainFieldStillUseSynchronizedLyrics(malformedSyncedField: Bool) async throws {
        LyricHTTPFixture.reset([.json(record(plain: "[00:14.20]The room grows quiet\n[00:20.74]The morning light returns",
            synced: malformedSyncedField ? "[00:broken]Invalid timing" : nil))])
        let resolver = LyricsResolver(cacheDirectory: nil, session: session())
        let result = try await resolver.request(for: track) { _ in throw LyricFailure.unavailable }
        #expect(result.synchronization == .lineSynced)
        #expect(result.lines.map(\.startTimeMs) == [14_200, 20_740])
        #expect(result.lines.map(\.text) == ["The room grows quiet", "The morning light returns"])
        #expect(result.providerDisplayName == "LRCLIB")
    }

    @Test(arguments: [false, true])
    func legacyTimestampedPlainCacheRecoversTimingWithoutClearingLyrics(stale: Bool) async throws {
        LyricHTTPFixture.reset([])
        let cache = try directory(); defer { try? FileManager.default.removeItem(at: cache) }
        let clock = LyricResolverClock()
        let resolver = LyricsResolver(cacheDirectory: cache, session: session(), now: { clock.now })
        let seed = lyric()
        _ = try await resolver.request(for: track) { _ in seed }
        let file = try #require(FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil).first)
        var entry = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        entry["provider"] = "lrclib"
        entry["displayName"] = "LRCLIB"
        entry["lines"] = [["text": "[00:14.20]The room grows quiet"], ["text": "[00:20.74]The morning light returns"]]
        try JSONSerialization.data(withJSONObject: entry).write(to: file)
        if stale {
            clock.advance(31 * 86_400)
            LyricHTTPFixture.reset([.status(500), .status(500)])
        }
        let recovered = try await resolver.request(for: track) { _ in
            if !stale { Issue.record("A fresh cached result must not require Spotify") }
            throw LyricFailure.network
        }
        #expect(recovered.synchronization == .lineSynced)
        #expect(recovered.lines.map(\.startTimeMs) == [14_200, 20_740])
        #expect(recovered.lines.map(\.text) == ["The room grows quiet", "The morning light returns"])
        #expect(LyricHTTPFixture.requests.count == (stale ? 2 : 0))
    }

    @Test(arguments: ["[Chorus]Everyone joins", "[ar:Artist]Sung words"])
    func mixedPlainLyricsAreNotPromotedByDiscardingBracketedWords(untimedLine: String) async throws {
        let plain = "[00:01.00]First line\n" + untimedLine
        LyricHTTPFixture.reset([.json(record(plain: plain))])
        let resolver = LyricsResolver(cacheDirectory: nil, session: session())
        let result = try await resolver.request(for: track) { _ in throw LyricFailure.unavailable }
        #expect(result.synchronization == .unsynced)
        #expect(result.lines.map(\.text).joined(separator: "\n") == plain)
    }

    @Test func failedProviderRequestsAreNeverCachedAsNoLyrics() async throws {
        let cache = try directory(); defer { try? FileManager.default.removeItem(at: cache) }
        LyricHTTPFixture.reset([.status(500), .status(500), .json(record())])
        let resolver = LyricsResolver(cacheDirectory: cache, session: session())
        await #expect(throws: LyricFailure.network) { _ = try await resolver.request(for: track) { _ in throw LyricFailure.network } }
        let recovered = try await resolver.request(for: track) { _ in throw LyricFailure.network }
        #expect(recovered.provider == "lrclib" && LyricHTTPFixture.requests.count == 3)
    }

    @Test func oldPositiveCacheSurvivesAnOutage() async throws {
        let cache = try directory(); defer { try? FileManager.default.removeItem(at: cache) }
        let clock = LyricResolverClock()
        let resolver = LyricsResolver(cacheDirectory: cache, session: session(), now: { clock.now })
        let expected = lyric("Previously found")
        _ = try await resolver.request(for: track) { _ in expected }
        clock.advance(31 * 86_400)
        LyricHTTPFixture.reset([.status(500)])
        #expect(try await resolver.request(for: track) { _ in throw LyricFailure.network } == expected)
    }

    @Test func longRetryAfterPausesFollowingCallsWithoutSleepingOrSendingSearch() async throws {
        LyricHTTPFixture.reset([.status(429, retryAfter: "86400")])
        let resolver = LyricsResolver(cacheDirectory: nil, session: session())
        for _ in 0..<2 {
            await #expect(throws: LyricFailure.network) { _ = try await resolver.request(for: track) { _ in throw LyricFailure.network } }
        }
        #expect(LyricHTTPFixture.requests.count == 1)
    }

    @Test func shortRetryAfterIsHonoredBeforeASecondRequest() async throws {
        LyricHTTPFixture.reset([.status(429, retryAfter: "1"), .json(record())])
        let clock = LyricResolverClock()
        let resolver = LyricsResolver(cacheDirectory: nil, session: session(), now: { clock.now },
            sleep: { duration in clock.advance(Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18) })
        let start = clock.now
        let result = try await resolver.request(for: track) { _ in throw LyricFailure.network }
        #expect(result.provider == "lrclib" && clock.now.timeIntervalSince(start) >= 1)
        #expect(LyricHTTPFixture.requests.count == 2)
    }

    @Test func aTransientExactOutageStillSearchesAfterHonoringTheCooldown() async throws {
        LyricHTTPFixture.reset([.status(503, retryAfter: "0"), .status(503, retryAfter: "0"), .json([record()])])
        let clock = LyricResolverClock()
        let resolver = LyricsResolver(cacheDirectory: nil, session: session(), now: { clock.now },
            sleep: { duration in clock.advance(Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18) })
        let result = try await resolver.request(for: track) { _ in throw LyricFailure.network }
        #expect(result.provider == "lrclib")
        #expect(LyricHTTPFixture.requests.map { $0.url!.path } == ["/api/get", "/api/get", "/api/search"])
    }

    @Test(arguments: [false, true])
    func emptySearchAfterAnExactOutageRemainsAFailureInsteadOfNoLyrics(missingResponse: Bool) async throws {
        LyricHTTPFixture.reset([.status(500), missingResponse ? .status(404) : .json([])])
        let resolver = LyricsResolver(cacheDirectory: nil, session: session())
        await #expect(throws: LyricFailure.network) { _ = try await resolver.request(for: track) { _ in throw LyricFailure.network } }
        #expect(LyricHTTPFixture.requests.count == 2)
    }

    @Test(arguments: ["...", String(repeating: "long", count: 300)])
    func unsafeOrUnmatchableMetadataNeverLeavesTheApp(title: String) async throws {
        LyricHTTPFixture.reset([])
        let invalid = Track(uri: track.uri, title: title, artists: track.artists, albumTitle: track.albumTitle, artwork: nil, durationMs: track.durationMs)
        let resolver = LyricsResolver(cacheDirectory: nil, session: session())
        await #expect(throws: LyricFailure.noLyrics) { _ = try await resolver.request(for: invalid) { _ in throw LyricFailure.noLyrics } }
        #expect(LyricHTTPFixture.requests.isEmpty)
    }

    @Test func multipleTimestampsExpandInOrderWithoutDroppingRepeatedLines() async throws {
        LyricHTTPFixture.reset([.json(record(synced: "[ar:Soft Weather]\n[00:01.00][00:03.00]Repeated line\n[00:02.00]Middle"))])
        let resolver = LyricsResolver(cacheDirectory: nil, session: session())
        let result = try await resolver.request(for: track) { _ in throw LyricFailure.unavailable }
        #expect(result.lines.map(\.startTimeMs) == [1000, 2000, 3000])
        #expect(result.lines.map(\.text) == ["Repeated line", "Middle", "Repeated line"])
    }

    @Test func oversizedResponsesAreRejectedBeforeDecode() async throws {
        LyricHTTPFixture.reset([.init(status: 200, data: Data(repeating: 32, count: 1_048_577), retryAfter: nil)])
        let resolver = LyricsResolver(cacheDirectory: nil, session: session())
        await #expect(throws: LyricFailure.network) { _ = try await resolver.request(for: track) { _ in throw LyricFailure.network } }
    }

    @Test func cancellationDoesNotTurnIntoAFallbackRequest() async throws {
        LyricHTTPFixture.reset([])
        let resolver = LyricsResolver(cacheDirectory: nil, session: session())
        let task = Task { try await resolver.request(for: track) { _ in
            try await Task.sleep(for: .seconds(30)); throw LyricFailure.unavailable
        } }
        await Task.yield(); task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(LyricHTTPFixture.requests.isEmpty)
    }

    @Test func stalledSpotifyCannotHoldTheFallbackIndefinitely() async throws {
        LyricHTTPFixture.reset([.json(record())])
        let resolver = LyricsResolver(cacheDirectory: nil, session: session(), spotifyTimeout: .milliseconds(20))
        let began = ContinuousClock.now
        let result = try await resolver.request(for: track) { _ in
            try await Task.sleep(for: .seconds(30)); throw LyricFailure.unavailable
        }
        #expect(result.provider == "lrclib" && began.duration(to: .now) < .seconds(2))
    }

    @Test func lateSpotifyReplyCannotReplaceTheFallbackOrItsCache() async throws {
        let cache = try directory(); defer { try? FileManager.default.removeItem(at: cache) }
        LyricHTTPFixture.reset([.json(record())])
        let gate = LateSpotifyReply()
        let resolver = LyricsResolver(cacheDirectory: cache, session: session(), spotifyTimeout: .milliseconds(20))
        let fallback = try await resolver.request(for: track) { _ in try await gate.wait() }
        #expect(fallback.provider == "lrclib")
        await gate.finish(lyric("Late Spotify words"))
        for _ in 0..<10 { await Task.yield() }
        #expect(try await resolver.request(for: track) { _ in throw LyricFailure.network } == fallback)
        #expect(LyricHTTPFixture.requests.count == 1)
    }

    @Test func metadataReplacementCannotReuseAnotherRecordingsCache() async throws {
        let cache = try directory(); defer { try? FileManager.default.removeItem(at: cache) }
        let resolver = LyricsResolver(cacheDirectory: cache, session: session())
        let first = lyric("Original recording")
        _ = try await resolver.request(for: track) { _ in first }
        let replaced = Track(uri: track.uri, title: "Window Seat (Live)", artists: track.artists,
            albumTitle: track.albumTitle, artwork: nil, durationMs: 300_000)
        let expected = lyric("New recording")
        #expect(try await resolver.request(for: replaced) { _ in expected } == expected)
    }

    @Test func invalidSpotifyReplyFallsBackInsteadOfPoisoningTheCache() async throws {
        LyricHTTPFixture.reset([.json(record())])
        let resolver = LyricsResolver(cacheDirectory: nil, session: session())
        let wrong = TrackLyrics(trackURI: SpotifyURI("spotify:track:wrong")!, synchronization: .unsynced,
            lines: [TrackLyricLine(text: "Wrong track", startTimeMs: nil)], provider: "spotify", providerDisplayName: "Spotify", isRightToLeft: false)
        #expect(try await resolver.request(for: track) { _ in wrong }.provider == "lrclib")
    }
}

private final class LyricResolverClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date()
    var now: Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date += seconds } }
}

private final class LyricHTTPFixture: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        let status: Int
        let data: Data
        let retryAfter: String?
        static func json(_ value: Any) -> Reply { .init(status: 200, data: try! JSONSerialization.data(withJSONObject: value), retryAfter: nil) }
        static func status(_ value: Int, retryAfter: String? = nil) -> Reply { .init(status: value, data: Data(), retryAfter: retryAfter) }
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [Reply] = []
    nonisolated(unsafe) private static var captured: [URLRequest] = []
    static var requests: [URLRequest] { lock.withLock { captured } }
    static func reset(_ values: [Reply]) { lock.withLock { replies = values; captured = [] } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let reply = Self.lock.withLock {
            Self.captured.append(request)
            return Self.replies.isEmpty ? Reply.status(500) : Self.replies.removeFirst()
        }
        var headers = ["Content-Type": "application/json"]
        headers["Retry-After"] = reply.retryAfter
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private actor LateSpotifyReply {
    private var continuation: CheckedContinuation<TrackLyrics, any Error>?
    func wait() async throws -> TrackLyrics {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish(_ lyrics: TrackLyrics) { continuation?.resume(returning: lyrics); continuation = nil }
}
