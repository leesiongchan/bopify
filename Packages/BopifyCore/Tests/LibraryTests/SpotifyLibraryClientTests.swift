import Foundation
import Testing
import BopifyDomain
@testable import BopifyLibrary

private final class LibraryProtocol: URLProtocol, @unchecked Sendable {
    static let fixture = LibraryFixture()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let result = Self.fixture.respond(request)
        if let error = result.error { client?.urlProtocol(self, didFailWithError: error); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: result.status, httpVersion: nil, headerFields: result.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: result.data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
private final class LibraryFixture: @unchecked Sendable {
    struct Response { var status = 200; var data = Data(); var headers: [String: String] = [:]; var error: URLError? }
    private let lock = NSLock()
    private var response = Response()
    private var recorded: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { recorded } }
    func reset(_ response: Response) { lock.withLock { self.response = response; recorded = [] } }
    func respond(_ request: URLRequest) -> Response { lock.withLock { recorded.append(request); return response } }
}
private final class LibraryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_000)
    func now() -> Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
}

@Suite("SpotifyLibraryClient", .serialized)
struct SpotifyLibraryClientTests {
    private let uri = SpotifyURI("spotify:track:abc")!
    private func client(scopes: Set<String>? = nil) -> SpotifyLibraryClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LibraryProtocol.self]
        return SpotifyLibraryClient(session: URLSession(configuration: configuration)) { required in
            if let scopes, !required.isSubset(of: scopes) { throw LibraryError.authorizationRequired }
            return "TEST_TOKEN"
        }
    }
    @Test func exactRequestContractAndEmptyMutationResponses() async throws {
        LibraryProtocol.fixture.reset(.init(data: Data("[true]".utf8)))
        let client = client()
        #expect(try await client.savedState(for: uri))
        LibraryProtocol.fixture.reset(.init())
        try await client.save(uri)
        try await client.remove(uri)
        let requests = LibraryProtocol.fixture.requests
        #expect(requests.map(\.httpMethod) == ["PUT", "DELETE"])
        for request in requests {
            #expect(request.url?.host == "api.spotify.com")
            #expect(request.url?.path == "/v1/me/library")
            #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "uris", value: uri.rawValue)])
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer TEST_TOKEN")
            #expect(request.httpBody == nil && request.httpBodyStream == nil)
        }
    }
    @Test(arguments: ["[]", "[true,false]", "[1]", "null", "{", "[\"true\"]"])
    func malformedContainsNeverMeansUnsaved(body: String) async {
        LibraryProtocol.fixture.reset(.init(data: Data(body.utf8)))
        await #expect(throws: LibraryError.invalidResponse) { _ = try await client().savedState(for: uri) }
    }
    @Test func falseIsAValidConfirmedState() async throws {
        LibraryProtocol.fixture.reset(.init(data: Data("[false]".utf8)))
        #expect(try await client().savedState(for: uri) == false)
        let request = try #require(LibraryProtocol.fixture.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/v1/me/library/contains")
    }
    @Test func corruptLibraryCredentialsOfferConsentWithoutStartingAnAPIRequest() async {
        LibraryProtocol.fixture.reset(.init())
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LibraryProtocol.self]
        let library = SpotifyLibraryClient(session: URLSession(configuration: config)) { _ in
            throw PlayerError.credentialCorrupt
        }
        await #expect(throws: LibraryError.authorizationRequired) { try await library.savedState(for: uri) }
        #expect(LibraryProtocol.fixture.requests.isEmpty)
    }

    @Test func statusMappingAndNoRetries() async {
        for (status, error) in [(400, LibraryError.invalidResponse), (401, .authorizationRequired), (403, .forbidden), (429, .rateLimited(retryAfterSeconds: 12)), (500, .unavailable)] {
            LibraryProtocol.fixture.reset(.init(status: status, headers: ["Retry-After": "12"]))
            await #expect(throws: error) { try await client().save(uri) }
            #expect(LibraryProtocol.fixture.requests.count == 1)
        }
    }
    @Test func concurrentLibraryFeaturesShareEstablishedCooldown() async {
        let uri = self.uri
        LibraryProtocol.fixture.reset(.init(status: 429, headers: ["Retry-After": "12"]))
        let client = client()
        await #expect(throws: LibraryError.rateLimited(retryAfterSeconds: 12)) {
            _ = try await client.savedTracks(offset: 0, limit: 50)
        }
        LibraryProtocol.fixture.reset(.init())
        let blocked = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do { _ = try await client.savedState(for: uri); return false }
                catch { return error as? LibraryError == .rateLimited(retryAfterSeconds: 12) }
            }
            group.addTask {
                do { _ = try await client.savedTracks(offset: 0, limit: 50); return false }
                catch { return error as? LibraryError == .rateLimited(retryAfterSeconds: 12) }
            }
            var results: [Bool] = []
            for await result in group { results.append(result) }
            return results
        }
        #expect(blocked == [true, true])
        #expect(LibraryProtocol.fixture.requests.isEmpty)
    }
    @Test func cooldownExpiresForBothLibraryFeatures() async throws {
        let clock = LibraryClock()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LibraryProtocol.self]
        let client = SpotifyLibraryClient(session: URLSession(configuration: configuration),
                                          tokenProvider: { _ in "TEST_TOKEN" }, now: { clock.now() })
        LibraryProtocol.fixture.reset(.init(status: 429, headers: ["Retry-After": "12"]))
        await #expect(throws: LibraryError.rateLimited(retryAfterSeconds: 12)) {
            _ = try await client.savedTracks(offset: 0, limit: 50)
        }
        clock.advance(11)
        LibraryProtocol.fixture.reset(.init(data: Data("[true]".utf8)))
        await #expect(throws: LibraryError.rateLimited(retryAfterSeconds: 1)) { _ = try await client.savedState(for: uri) }
        #expect(LibraryProtocol.fixture.requests.isEmpty)
        clock.advance(1)
        #expect(try await client.savedState(for: uri))
        #expect(LibraryProtocol.fixture.requests.count == 1)
    }
    @Test @MainActor func featuresJoiningCooldownKeepTheOriginalDeadline() async throws {
        let clock = LibraryClock()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LibraryProtocol.self]
        let client = SpotifyLibraryClient(session: URLSession(configuration: configuration),
                                          tokenProvider: { _ in "TEST_TOKEN" }, now: { clock.now() })
        let liked = LikedSongsModel(service: client, now: { clock.now() })
        let recents = RecentsModel(service: client, now: { clock.now() })
        LibraryProtocol.fixture.reset(.init(status: 429, headers: ["Retry-After": "12"]))
        await liked.reveal(at: clock.now())
        #expect(liked.retryAfter == Date(timeIntervalSince1970: 1_012))
        clock.advance(11)
        await recents.reveal(at: clock.now())
        #expect(recents.error == .rateLimited(retryAfterSeconds: 1))
        #expect(recents.retryAfter == liked.retryAfter)
        #expect(LibraryProtocol.fixture.requests.count == 1)
        clock.advance(1)
        LibraryProtocol.fixture.reset(.init(data: Data(#"{"items":[]}"#.utf8)))
        await recents.retry(at: clock.now())
        #expect(recents.error == nil && recents.retryAfter == nil)
        #expect(LibraryProtocol.fixture.requests.count == 1)
    }
    @Test(arguments: [false, true])
    func sharedCooldownRoundsUpOnlyTheRemainingDelay(quota: Bool) async {
        let clock = LibraryClock()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LibraryProtocol.self]
        let client = SpotifyLibraryClient(session: URLSession(configuration: configuration),
                                          tokenProvider: { _ in "TEST_TOKEN" }, now: { clock.now() })
        let body = quota ? #"{"error":{"status":429,"message":"Too many requests","reason":"QUOTA_EXCEEDED"}}"# : ""
        LibraryProtocol.fixture.reset(.init(status: 429, data: Data(body.utf8), headers: ["Retry-After": "12"]))
        let initial: LibraryError = quota ? .quotaExceeded(retryAfterSeconds: 12) : .rateLimited(retryAfterSeconds: 12)
        await #expect(throws: initial) { _ = try await client.savedTracks(offset: 0, limit: 50) }
        clock.advance(10.25)
        let remaining: LibraryError = quota ? .quotaExceeded(retryAfterSeconds: 2) : .rateLimited(retryAfterSeconds: 2)
        await #expect(throws: remaining) { _ = try await client.savedState(for: uri) }
        #expect(LibraryProtocol.fixture.requests.count == 1)
    }
    @Test(arguments: ["missing", "invalid", "-1"])
    func sharedCooldownUsesTheRemainingDefaultDelay(header: String) async {
        let clock = LibraryClock()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LibraryProtocol.self]
        let client = SpotifyLibraryClient(session: URLSession(configuration: configuration),
                                          tokenProvider: { _ in "TEST_TOKEN" }, now: { clock.now() })
        LibraryProtocol.fixture.reset(.init(status: 429, headers: header == "missing" ? [:] : ["Retry-After": header]))
        await #expect(throws: LibraryError.rateLimited(retryAfterSeconds: nil)) { try await client.save(uri) }
        clock.advance(59)
        await #expect(throws: LibraryError.rateLimited(retryAfterSeconds: 1)) { try await client.remove(uri) }
        #expect(LibraryProtocol.fixture.requests.count == 1)
    }
    @Test func sharedCooldownAcceptsTheLargestServerDelay() async {
        let client = client()
        LibraryProtocol.fixture.reset(.init(status: 429, headers: ["Retry-After": String(Int.max)]))
        await #expect(throws: LibraryError.rateLimited(retryAfterSeconds: Int.max)) { try await client.save(uri) }
        do {
            try await client.remove(uri)
            Issue.record("The shared cooldown must block another request")
        } catch let LibraryError.rateLimited(seconds) {
            #expect((seconds ?? 0) > 1_000_000_000)
        } catch { Issue.record(error) }
        #expect(LibraryProtocol.fixture.requests.count == 1)
    }
    @Test func unsupportedAndMissingScopesDoNotSendRequests() async {
        LibraryProtocol.fixture.reset(.init())
        await #expect(throws: LibraryError.authorizationRequired) { _ = try await client(scopes: []).savedState(for: uri) }
        await #expect(throws: LibraryError.unavailable) { try await client().save(SpotifyURI("spotify:album:abc")!) }
        await #expect(throws: LibraryError.unavailable) { try await client().save(SpotifyURI("spotify:track:abc,def")!) }
        #expect(LibraryProtocol.fixture.requests.isEmpty)
    }
    @Test func networkFailureAndCancellationRemainDistinct() async {
        LibraryProtocol.fixture.reset(.init(error: URLError(.timedOut)))
        await #expect(throws: LibraryError.unavailable) { try await client().save(uri) }
        LibraryProtocol.fixture.reset(.init(error: URLError(.cancelled)))
        await #expect(throws: CancellationError.self) { try await client().save(uri) }
    }
    @Test func redirectPolicyDoesNotForwardBearerCredentials() async {
        var request = URLRequest(url: URL(string: "https://example.com/redirect")!)
        request.setValue("Bearer TEST_TOKEN", forHTTPHeaderField: "Authorization")
        let response = HTTPURLResponse(url: URL(string: "https://api.spotify.com/v1/me/library")!, statusCode: 302, httpVersion: nil, headerFields: nil)!
        let task = URLSession.shared.dataTask(with: request)
        await withCheckedContinuation { continuation in
            LibraryRedirectPolicy().urlSession(.shared, task: task, willPerformHTTPRedirection: response, newRequest: request) { forwarded in
                #expect(forwarded == nil)
                continuation.resume()
            }
        }
    }

    @Test(arguments: CatalogSearchKind.allCases)
    func musicLinksUseExactMetadataEndpoints(_ kind: CatalogSearchKind) async throws {
        let body: Any = kind == .song ? savedTrack("abc")["track"]! : [
            "uri": "spotify:\(kind.rawValue):abc", "name": "Exact item",
            "artists": [["name": "Artist"]], "images": [["url": "https://i.scdn.co/image/cover"]]
        ]
        LibraryProtocol.fixture.reset(.init(data: try JSONSerialization.data(withJSONObject: body)))
        let pages = try await client().search(query: "https://open.spotify.com/intl-my/\(kind.rawValue)/abc?si=private",
            kinds: Set(CatalogSearchKind.allCases), offset: 0, limit: 10)
        #expect(Set(pages.keys) == Set(CatalogSearchKind.allCases))
        #expect(pages[kind]?.results.first?.uri == SpotifyURI("spotify:\(kind.rawValue):abc"))
        #expect(pages.values.flatMap(\.results).count == 1)
        #expect(pages.values.allSatisfy { $0.nextOffset == nil })
        let request = try #require(LibraryProtocol.fixture.requests.first)
        let path = kind == .song ? "tracks" : "\(kind.rawValue)s"
        #expect(request.url?.path == "/v1/\(path)/abc")
        #expect(request.url?.host == "api.spotify.com" && request.url?.scheme == "https")
        #expect(request.url?.query == nil && request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer TEST_TOKEN")
        #expect(LibraryProtocol.fixture.requests.count == 1)
        if kind == .playlist {
            #expect(pages[kind]?.results.first?.subtitle == "")
        }
    }

    @Test func linkLookupUsesOnlyExistingRequiredScopes() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LibraryProtocol.self]
        let library = SpotifyLibraryClient(session: URLSession(configuration: configuration)) { required in
            #expect(required == ["playlist-read-private", "playlist-read-collaborative"])
            return "TEST_TOKEN"
        }
        LibraryProtocol.fixture.reset(.init(data: Data(#"{"uri":"spotify:playlist:abc","name":"Private playlist"}"#.utf8)))
        let pages = try await library.search(query: "spotify:playlist:abc", kinds: [.playlist], offset: 0, limit: 10)
        #expect(pages[.playlist]?.results.first?.artwork == nil)
        LibraryProtocol.fixture.reset(.init(data: try JSONSerialization.data(withJSONObject: savedTrack("abc")["track"]!)))
        _ = try await client(scopes: []).search(query: "spotify:track:abc", kinds: [.song], offset: 0, limit: 10)
    }

    @Test func linksHaveNoOtherKindsOrSubsequentPages() async throws {
        LibraryProtocol.fixture.reset(.init())
        let library = client()
        let excluded = try await library.search(query: "spotify:track:abc", kinds: [.album], offset: 0, limit: 10)
        let subsequent = try await library.search(query: "spotify:track:abc", kinds: [.song], offset: 10, limit: 10)
        #expect(excluded == [.album: CatalogSearchPage(results: [], nextOffset: nil)])
        #expect(subsequent == [.song: CatalogSearchPage(results: [], nextOffset: nil)])
        #expect(LibraryProtocol.fixture.requests.isEmpty)
    }

    @Test func invalidAndUnsupportedLinksNeverSendRequests() async {
        LibraryProtocol.fixture.reset(.init())
        for (query, error) in [("https://open.spotify.com.evil.test/track/abc", LibraryError.invalidLink),
                               ("spotify:track:bad,id", .invalidLink), ("spotify:episode:abc", .unsupportedLink),
                               ("https://spotify.link/opaque", .unsupportedLink)] {
            await #expect(throws: error) {
                _ = try await client().search(query: query, kinds: [.song], offset: 0, limit: 10)
            }
        }
        #expect(LibraryProtocol.fixture.requests.isEmpty)
    }

    @Test func linkLookupAcceptsRelinkedPlayableTracks() async throws {
        LibraryProtocol.fixture.reset(.init(data: try JSONSerialization.data(withJSONObject: savedTrack("regional")["track"]!)))
        let pages = try await client().search(query: "spotify:track:original", kinds: [.song], offset: 0, limit: 10)
        #expect(pages[.song]?.results.first?.uri == SpotifyURI("spotify:track:regional"))
    }

    @Test(arguments: [
        #"{"uri":"spotify:artist:abc","name":"Wrong kind"}"#,
        #"{"uri":"spotify:album:other","name":"Wrong album"}"#,
        #"{"uri":"spotify:album:abc","name":""}"#,
        "{}", "null"
    ])
    func linkLookupRejectsInvalidMetadata(_ body: String) async {
        LibraryProtocol.fixture.reset(.init(data: Data(body.utf8)))
        await #expect(throws: LibraryError.invalidResponse) {
            _ = try await client().search(query: "spotify:album:abc", kinds: [.album], offset: 0, limit: 10)
        }
    }

    @Test(arguments: ["is_local", "is_playable"])
    func unavailableLinkTracksAreNotPlayable(_ flag: String) async throws {
        var track = savedTrack("abc")["track"] as! [String: Any]
        track[flag] = flag == "is_local"
        LibraryProtocol.fixture.reset(.init(data: try JSONSerialization.data(withJSONObject: track)))
        await #expect(throws: LibraryError.notFound) {
            _ = try await client().search(query: "spotify:track:abc", kinds: [.song], offset: 0, limit: 10)
        }
    }

    @Test func linkLookupPreservesErrorsCancellationAndSharedCooldown() async {
        for (status, error) in [(401, LibraryError.authorizationRequired), (403, .forbidden), (404, .notFound),
                               (429, .rateLimited(retryAfterSeconds: 12)), (503, .unavailable)] {
            LibraryProtocol.fixture.reset(.init(status: status, headers: ["Retry-After": "12"]))
            await #expect(throws: error) {
                _ = try await client().search(query: "spotify:track:abc", kinds: [.song], offset: 0, limit: 10)
            }
            #expect(LibraryProtocol.fixture.requests.count == 1)
        }
        let library = client()
        LibraryProtocol.fixture.reset(.init(status: 429,
            data: Data(#"{"error":{"reason":"QUOTA_EXCEEDED"}}"#.utf8), headers: ["Retry-After": "12"]))
        await #expect(throws: LibraryError.quotaExceeded(retryAfterSeconds: 12)) {
            _ = try await library.search(query: "spotify:track:abc", kinds: [.song], offset: 0, limit: 10)
        }
        await #expect(throws: LibraryError.quotaExceeded(retryAfterSeconds: 12)) { _ = try await library.savedState(for: uri) }
        #expect(LibraryProtocol.fixture.requests.count == 1)
        LibraryProtocol.fixture.reset(.init(error: URLError(.cancelled)))
        await #expect(throws: CancellationError.self) {
            _ = try await client().search(query: "spotify:track:abc", kinds: [.song], offset: 0, limit: 10)
        }
        LibraryProtocol.fixture.reset(.init(error: URLError(.timedOut)))
        await #expect(throws: LibraryError.unavailable) {
            _ = try await client().search(query: "spotify:track:abc", kinds: [.song], offset: 0, limit: 10)
        }
    }

    @Test func URLTextWithinAQueryStillUsesCatalogSearch() async throws {
        LibraryProtocol.fixture.reset(.init(data: try JSONSerialization.data(withJSONObject: ["tracks": catalogPage([])])))
        let text = #"track:"https://example.com""#
        _ = try await client().search(query: text, kinds: [.song], offset: 0, limit: 2)
        let request = try #require(LibraryProtocol.fixture.requests.first)
        #expect(request.url?.path == "/v1/search")
        #expect(query(request)?.first == URLQueryItem(name: "q", value: text))
    }

    @Test func searchEncodesQueryAndUsesLibraryTokenWithoutUserScopes() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LibraryProtocol.self]
        let client = SpotifyLibraryClient(session: URLSession(configuration: configuration)) { scopes in
            #expect(scopes.isEmpty)
            return "CATALOG_LIBRARY_TOKEN"
        }
        let track = savedTrack("a")["track"]!
        let data = try JSONSerialization.data(withJSONObject: ["tracks": ["items": [track, NSNull()],
            "offset": 0, "limit": 10, "total": 12, "next": "https://untrusted.invalid/?offset=999"]])
        LibraryProtocol.fixture.reset(.init(data: data))
        let page = try await client.search(query: "  Björk & year:2026  ", kinds: [.song], offset: 0, limit: 10)
        #expect(page[.song]?.results.map(\.uri.rawValue) == ["spotify:track:a"])
        #expect(page[.song]?.nextOffset == 2)
        let request = try #require(LibraryProtocol.fixture.requests.first)
        #expect(request.url?.path == "/v1/search")
        #expect(request.url?.host == "api.spotify.com")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer CATALOG_LIBRARY_TOKEN")
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
        #expect(query == [URLQueryItem(name: "q", value: "Björk & year:2026"),
            URLQueryItem(name: "type", value: "track"), URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "limit", value: "10")])
    }

    @Test func catalogSearchEncodesAllKindsAndUsesNoUserScopes() async throws {
        let body = ["tracks": catalogPage([]), "albums": catalogPage([]),
                    "artists": catalogPage([]), "playlists": catalogPage([])]
        LibraryProtocol.fixture.reset(.init(data: try JSONSerialization.data(withJSONObject: body)))
        let pages = try await client(scopes: []).search(query: "  Björk 🎵 & year:2026  ",
            kinds: [.song, .album, .artist, .playlist], offset: 0, limit: 2)
        #expect(Set(pages.keys) == [.song, .album, .artist, .playlist])
        let request = try #require(LibraryProtocol.fixture.requests.first)
        #expect(request.url?.host == "api.spotify.com" && request.url?.path == "/v1/search")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer TEST_TOKEN")
        #expect(query(request) == [URLQueryItem(name: "q", value: "Björk 🎵 & year:2026"),
            URLQueryItem(name: "type", value: "track,album,artist,playlist"),
            URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "2")])
    }

    @Test func catalogSearchDecodesAllKindsAndPlaylistOwner() async throws {
        let body = ["tracks": catalogPage([savedTrack("a")["track"]!]),
            "albums": catalogPage([["uri": "spotify:album:b", "name": "Album b",
                "artists": [["name": "Mira Vale"]], "images": [["url": "https://i.scdn.co/image/b"]]]]),
            "artists": catalogPage([["uri": "spotify:artist:c", "name": "Mira Vale", "images": []]]),
            "playlists": catalogPage([["uri": "spotify:playlist:d", "name": "Playlist d",
                "owner": ["display_name": "Mira Vale"], "images": []]])]
        LibraryProtocol.fixture.reset(.init(data: try JSONSerialization.data(withJSONObject: body)))
        let pages = try await client().search(query: "Mira", kinds: [.song, .album, .artist, .playlist], offset: 0, limit: 2)
        #expect(pages[.song]?.results == [.song(Track(uri: SpotifyURI("spotify:track:a")!, title: "Song a",
            artists: [ArtistSummary(name: "Artist")], albumTitle: "Album",
            artwork: Artwork(url: URL(string: "https://i.scdn.co/image/cover")!), durationMs: 180_000))])
        #expect(pages[.album]?.results == [.album(LibraryCollection(uri: SpotifyURI("spotify:album:b")!,
            title: "Album b", subtitle: "Mira Vale", artwork: Artwork(url: URL(string: "https://i.scdn.co/image/b")!)))])
        #expect(pages[.artist]?.results == [.artist(LibraryCollection(uri: SpotifyURI("spotify:artist:c")!,
            title: "Mira Vale", subtitle: "", artwork: nil))])
        #expect(pages[.playlist]?.results == [.playlist(LibraryCollection(uri: SpotifyURI("spotify:playlist:d")!,
            title: "Playlist d", subtitle: "Mira Vale", artwork: nil))])
        for (kind, page) in pages {
            #expect(page.results.first?.kind == kind)
            #expect(page.nextOffset == nil)
        }
    }

    @Test(arguments: ["null", "wrongKind", "invalidURI", "missingOwner", "nullOwner", "missingArtwork", "unsafeArtwork"])
    func catalogSearchSkipsMalformedRowsBeforeDerivingDisplayResults(_ scenario: String) async throws {
        var item: [String: Any] = ["uri": "spotify:playlist:a", "name": "Playlist a",
            "owner": ["display_name": "Mira Vale"], "images": [["url": "https://i.scdn.co/image/a"]]]
        var invalid: Any = NSNull()
        switch scenario {
        case "wrongKind": invalid = ["uri": "spotify:album:wrong", "name": "Wrong"]
        case "invalidURI": invalid = ["uri": "spotify:playlist:bad,id", "name": "Wrong"]
        case "missingOwner": item.removeValue(forKey: "owner")
        case "nullOwner": item["owner"] = NSNull()
        case "missingArtwork": item.removeValue(forKey: "images")
        case "unsafeArtwork": item["images"] = [["url": "http://localhost/artwork"]]
        default: break
        }
        let body = ["tracks": catalogPage([savedTrack("a")["track"]!, NSNull()], total: 4, next: true),
            "playlists": catalogPage([item, invalid], total: 4, next: true)]
        LibraryProtocol.fixture.reset(.init(data: try JSONSerialization.data(withJSONObject: body)))
        let pages = try await client().search(query: "a", kinds: [.song, .playlist], offset: 0, limit: 2)
        #expect(pages[.song]?.results.map(\.uri.rawValue) == ["spotify:track:a"])
        #expect(pages[.song]?.nextOffset == 2)
        let result = try #require(pages[.playlist]?.results.first)
        #expect(pages[.playlist]?.results.count == 1 && pages[.playlist]?.nextOffset == 2)
        #expect(result.uri.rawValue == "spotify:playlist:a" && result.title == "Playlist a")
        #expect(result.subtitle == (["missingOwner", "nullOwner"].contains(scenario) ? "" : "Mira Vale"))
        #expect(result.artwork?.url.absoluteString == (["missingArtwork", "unsafeArtwork"].contains(scenario) ? nil : "https://i.scdn.co/image/a"))
    }

    @Test func catalogSearchPaginatesOnlyRequestedKinds() async throws {
        let items = (0..<10).map { ["uri": "spotify:playlist:p\($0)", "name": "Playlist \($0)"] }
        let body = ["playlists": catalogPage(items, offset: 2, limit: 10, total: 15, next: true)]
        LibraryProtocol.fixture.reset(.init(data: try JSONSerialization.data(withJSONObject: body)))
        let pages = try await client().search(query: "playlist", kinds: [.playlist], offset: 2, limit: 10)
        #expect(Set(pages.keys) == [.playlist])
        #expect(pages[.playlist]?.results.count == 10 && pages[.playlist]?.nextOffset == 12)
        #expect(query(LibraryProtocol.fixture.requests.first) == [URLQueryItem(name: "q", value: "playlist"),
            URLQueryItem(name: "type", value: "playlist"), URLQueryItem(name: "offset", value: "2"),
            URLQueryItem(name: "limit", value: "10")])
    }

    @Test func catalogSearchRejectsInvalidInputsAndRequestedPageShapes() async throws {
        let invalidInputs: [(String, Set<CatalogSearchKind>, Int, Int)] = [
            (" ", [.song], 0, 2), ("song", [], 0, 2), ("song", [.song], -1, 2),
            ("song", [.song], 1001, 2), ("song", [.song], 0, 0), ("song", [.song], 0, 11)]
        LibraryProtocol.fixture.reset(.init())
        for (text, kinds, offset, limit) in invalidInputs {
            await #expect(throws: LibraryError.invalidResponse) {
                _ = try await client().search(query: text, kinds: kinds, offset: offset, limit: limit)
            }
        }
        #expect(LibraryProtocol.fixture.requests.isEmpty)
        let badPages: [[String: Any]] = [[:], ["tracks": NSNull()],
            ["tracks": catalogPage([], offset: 1)], ["tracks": catalogPage([], limit: 10)],
            ["tracks": catalogPage([], total: -1)], ["tracks": catalogPage([NSNull(), NSNull(), NSNull()])]]
        for body in badPages {
            LibraryProtocol.fixture.reset(.init(data: try JSONSerialization.data(withJSONObject: body)))
            await #expect(throws: LibraryError.invalidResponse) {
                _ = try await client().search(query: "song", kinds: [.song], offset: 0, limit: 2)
            }
        }
        LibraryProtocol.fixture.reset(.init(data: Data("{".utf8)))
        await #expect(throws: LibraryError.invalidResponse) {
            _ = try await client().search(query: "song", kinds: [.song], offset: 0, limit: 2)
        }
    }

    @Test func catalogSearchStopsAtOffsetCeilingAndKeepsSharedCooldown() async throws {
        let body = ["tracks": catalogPage([savedTrack("a")["track"]!, NSNull()], offset: 1000, total: 1005, next: true)]
        LibraryProtocol.fixture.reset(.init(data: try JSONSerialization.data(withJSONObject: body)))
        let pages = try await client().search(query: "song", kinds: [.song], offset: 1000, limit: 2)
        #expect(pages[.song]?.nextOffset == nil)
        let clock = LibraryClock()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LibraryProtocol.self]
        let client = SpotifyLibraryClient(session: URLSession(configuration: configuration),
            tokenProvider: { _ in "TEST_TOKEN" }, now: { clock.now() })
        LibraryProtocol.fixture.reset(.init(status: 429, headers: ["Retry-After": "12"]))
        await #expect(throws: LibraryError.rateLimited(retryAfterSeconds: 12)) {
            _ = try await client.search(query: "song", kinds: [.song], offset: 0, limit: 2)
        }
        await #expect(throws: LibraryError.rateLimited(retryAfterSeconds: 12)) { _ = try await client.savedState(for: uri) }
        #expect(LibraryProtocol.fixture.requests.count == 1)
        clock.advance(12)
        LibraryProtocol.fixture.reset(.init(data: Data("[true]".utf8)))
        #expect(try await client.savedState(for: uri))
    }

    private func catalogPage(_ items: [Any], offset: Int = 0, limit: Int = 2,
                             total: Int? = nil, next: Bool = false) -> [String: Any] {
        ["items": items, "offset": offset, "limit": limit, "total": total ?? items.count,
         "next": next ? "https://untrusted.invalid/?offset=999" as Any : NSNull()]
    }

    @Test func followedArtistsAreLibraryCollections() async throws {
        let kind = try #require(LibraryCollectionKind(rawValue: "artists"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LibraryProtocol.self]
        let client = SpotifyLibraryClient(session: URLSession(configuration: configuration)) { scopes in
            #expect(scopes == ["user-follow-read"])
            return "ARTISTS"
        }
        let entity: [String: Any] = ["uri": "spotify:artist:artistA", "name": "Artist A",
            "images": [["url": "https://i.scdn.co/image/artist"]]]
        let data = try JSONSerialization.data(withJSONObject: ["artists": ["items": [entity, NSNull(), ["uri": "spotify:album:wrong", "name": "Wrong"]],
            "cursors": ["after": "artistA"], "next": "https://untrusted.invalid/next"]])
        LibraryProtocol.fixture.reset(.init(data: data))
        let page = try await client.savedCollections(kind, cursor: .after(nil), limit: 50)
        #expect(page.items.count == 1 && page.nextCursor == .after("artistA"))
        #expect(page.items.first?.uri == SpotifyURI("spotify:artist:artistA"))
        #expect(page.items.first?.artwork?.url.absoluteString == "https://i.scdn.co/image/artist")
        #expect(LibraryProtocol.fixture.requests.first?.url?.path == "/v1/me/following")
        let firstURL = try #require(LibraryProtocol.fixture.requests.first?.url)
        let initialQuery = URLComponents(url: firstURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(initialQuery.contains(URLQueryItem(name: "type", value: "artist")))
        #expect(!initialQuery.contains { $0.name == "offset" || $0.name == "after" })
        let last = try JSONSerialization.data(withJSONObject: ["artists": ["items": [], "cursors": ["after": "artistA"], "next": NSNull()]])
        LibraryProtocol.fixture.reset(.init(data: last))
        let final = try await client.savedCollections(kind, cursor: .after("artistA"), limit: 50)
        #expect(final.items.isEmpty && final.nextCursor == nil)
        let nextURL = try #require(LibraryProtocol.fixture.requests.first?.url)
        #expect(nextURL.host == "api.spotify.com")
        #expect(URLComponents(url: nextURL, resolvingAgainstBaseURL: false)?.queryItems?.contains(URLQueryItem(name: "after", value: "artistA")) == true)
    }

    @Test(arguments: ["missing", "repeated", "empty"])
    func artistContinuationMustProvideANewCursor(failure: String) async throws {
        let cursor: Any = failure == "missing" ? NSNull() : failure == "empty" ? "" : "same"
        let data = try JSONSerialization.data(withJSONObject: ["artists": ["items": [["uri": "spotify:artist:a", "name": "A"]],
            "cursors": ["after": cursor], "next": "https://api.spotify.com/v1/me/following"]])
        LibraryProtocol.fixture.reset(.init(data: data))
        await #expect(throws: LibraryError.invalidResponse) {
            try await client().savedCollections(.artists, cursor: .after("same"), limit: 50)
        }
    }

    @Test func collectionPagesUseExactEndpointsScopesAndRealContextURIs() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LibraryProtocol.self]
        for kind in [LibraryCollectionKind.playlists, .albums] {
            let expectedScopes: Set<String> = kind == .albums ? ["user-library-read"] : ["playlist-read-private", "playlist-read-collaborative"]
            let client = SpotifyLibraryClient(session: URLSession(configuration: configuration)) { scopes in
                #expect(scopes == expectedScopes)
                return "COLLECTIONS"
            }
            let entity: [String: Any] = ["uri": "spotify:\(kind == .albums ? "album" : "playlist"):abc", "name": "Collection",
                "artists": [["name": "Artist"]], "owner": ["display_name": "Owner"],
                "images": [["url": "https://i.scdn.co/image/cover"]]]
            let first: [String: Any] = kind == .albums ? ["album": entity] : entity
            let items: [Any] = [first, NSNull(), ["uri": "spotify:track:wrong", "name": "Wrong"]]
            let data = try JSONSerialization.data(withJSONObject: ["items": items, "offset": 0, "limit": 50,
                "total": 51, "next": "https://untrusted.invalid/next"])
            LibraryProtocol.fixture.reset(.init(data: data))
            let page = try await client.savedCollections(kind, cursor: .offset(0), limit: 50)
            #expect(page.items.count == 1 && page.nextCursor == .offset(3))
            #expect(page.items.first?.uri.kind == (kind == .albums ? .album : .playlist))
            #expect(page.items.first?.subtitle == (kind == .albums ? "Artist" : "Owner"))
            let request = try #require(LibraryProtocol.fixture.requests.first)
            #expect(request.url?.path == "/v1/me/\(kind.rawValue)")
            #expect(request.url?.host == "api.spotify.com")
        }
    }

    @Test func missingCollectionArtworkIsAllowedAndWrongIdentifiersAreSkipped() async throws {
        let body = #"{"items":[{"uri":"spotify:playlist:a","name":"No artwork","owner":{"display_name":null},"images":[]},{"uri":"spotify:playlist:bad,id","name":"Bad"},{"uri":"spotify:album:wrong","name":"Wrong"}],"offset":0,"limit":50,"total":3,"next":null}"#
        LibraryProtocol.fixture.reset(.init(data: Data(body.utf8)))
        let page = try await client().savedCollections(.playlists, cursor: .offset(0), limit: 50)
        #expect(page.items.count == 1)
        #expect(page.items.first?.artwork == nil)
        #expect(page.nextCursor == nil)
    }

    private func savedTrack(_ id: String, image: Bool = true) -> [String: Any] {
        ["track": ["uri": "spotify:track:\(id)", "name": "Song \(id)",
                   "artists": [["name": "Artist"]], "duration_ms": 180_000,
                   "album": ["name": "Album", "images": image ? [["url": "https://i.scdn.co/image/cover"]] : []]]]
    }
    private func savedPage(_ items: [Any], offset: Int = 0, limit: Int = 50, total: Int = 7,
                           next: String? = "https://api.spotify.com/v1/me/tracks?offset=3") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["items": items, "offset": offset,
            "limit": limit, "total": total, "next": next as Any? ?? NSNull()])
    }
    @Test(arguments: [5, 50]) func savedTracksRequestUsesReadScope(limit: Int) async throws {
        LibraryProtocol.fixture.reset(.init(data: try savedPage([], limit: limit, total: 0, next: nil)))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LibraryProtocol.self]
        let client = SpotifyLibraryClient(session: URLSession(configuration: configuration)) { required in
            #expect(required == ["user-library-read"])
            return "TEST_TOKEN"
        }
        let page = try await client.savedTracks(offset: 0, limit: limit)
        #expect(page == SavedTracksPage(tracks: [], nextOffset: nil, total: 0))
        let request = try #require(LibraryProtocol.fixture.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.scheme == "https" && request.url?.host == "api.spotify.com")
        #expect(request.url?.path == "/v1/me/tracks")
        #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems == [
            URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: String(limit))])
    }
    @Test func libraryRequestsUseOnlyTheirRequiredScopesAndLibraryBearer() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LibraryProtocol.self]
        let readClient = SpotifyLibraryClient(session: URLSession(configuration: configuration)) { required in
            #expect(required == ["user-library-read"])
            return "LIBRARY_ONLY"
        }
        LibraryProtocol.fixture.reset(.init(data: try savedPage([], total: 0, next: nil)))
        _ = try await readClient.savedTracks(offset: 0, limit: 50)
        #expect(LibraryProtocol.fixture.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer LIBRARY_ONLY")
        let writeClient = SpotifyLibraryClient(session: URLSession(configuration: configuration)) { required in
            #expect(required == ["user-library-modify"])
            return "LIBRARY_ONLY"
        }
        LibraryProtocol.fixture.reset(.init())
        try await writeClient.save(uri)
        #expect(LibraryProtocol.fixture.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer LIBRARY_ONLY")
    }
    @Test func skippedTrackDoesNotChangeNextOffset() async throws {
        LibraryProtocol.fixture.reset(.init(data: try savedPage([savedTrack("a"), ["track": NSNull()], savedTrack("b")])))
        let page = try await client().savedTracks(offset: 0, limit: 50)
        #expect(page.tracks.count == 2)
        #expect(page.nextOffset == 3)
        #expect(page.total == 7)
        #expect(page.tracks.map(\.uri.rawValue) == ["spotify:track:a", "spotify:track:b"])
        #expect(page.tracks[0].artwork == page.tracks[1].artwork)
    }
    @Test func invalidItemsAreSkippedAndMissingArtworkIsAllowed() async throws {
        var invalidURI = savedTrack("bad,id")
        var negative = savedTrack("negative")["track"] as! [String: Any]
        negative["duration_ms"] = -1
        var unavailable = savedTrack("unavailable")["track"] as! [String: Any]
        unavailable["is_playable"] = false
        invalidURI["added_at"] = "2026-09-27T00:00:00Z"
        let items: [Any] = [invalidURI, ["track": negative], ["track": unavailable], ["track": "bad"],
                            NSNull(), 42, [], [:], savedTrack("ok", image: false)]
        LibraryProtocol.fixture.reset(.init(data: try savedPage(items, total: 20)))
        let page = try await client().savedTracks(offset: 0, limit: 50)
        #expect(page.tracks.map(\.uri.rawValue) == ["spotify:track:ok"])
        #expect(page.tracks.first?.artwork == nil)
        #expect(page.nextOffset == 9)
        LibraryProtocol.fixture.reset(.init(data: try savedPage(Array(items.prefix(4)))))
        let skipped = try await client().savedTracks(offset: 0, limit: 50)
        #expect(skipped.tracks.isEmpty && skipped.nextOffset == 4)
    }
    @Test func paginationNeverFollowsResponseURL() async throws {
        LibraryProtocol.fixture.reset(.init(data: try savedPage([savedTrack("a")], next: "https://example.com/steal")))
        let client = client()
        let first = try await client.savedTracks(offset: 0, limit: 50)
        #expect(first.nextOffset == 1)
        LibraryProtocol.fixture.reset(.init(data: try savedPage([savedTrack("b")], offset: 1, next: nil)))
        let last = try await client.savedTracks(offset: 1, limit: 50)
        #expect(last.nextOffset == nil)
        #expect(LibraryProtocol.fixture.requests.allSatisfy { $0.url?.host == "api.spotify.com" })
        LibraryProtocol.fixture.reset(.init(data: try savedPage([], offset: 2)))
        #expect(try await client.savedTracks(offset: 2, limit: 50).nextOffset == nil)
    }
    @Test func malformedPagesAndInvalidArgumentsFail() async throws {
        for body in ["{}", "null", "{\"items\":[],\"offset\":0,\"limit\":50,\"total\":-1,\"next\":null}",
                     "{\"items\":[],\"offset\":1,\"limit\":50,\"total\":7,\"next\":null}",
                     "{\"items\":[],\"offset\":0,\"limit\":0,\"total\":7,\"next\":null}"] {
            LibraryProtocol.fixture.reset(.init(data: Data(body.utf8)))
            await #expect(throws: LibraryError.invalidResponse) { _ = try await client().savedTracks(offset: 0, limit: 50) }
        }
        LibraryProtocol.fixture.reset(.init())
        for (offset, limit) in [(-1, 50), (0, 0), (0, 51)] {
            await #expect(throws: LibraryError.invalidResponse) { _ = try await client().savedTracks(offset: offset, limit: limit) }
        }
        #expect(LibraryProtocol.fixture.requests.isEmpty)
    }
    @Test func savedPaginationRejectsExcessItemsAndOffsetOverflow() async throws {
        for (offset, count) in [(0, 51), (Int.max, 1)] {
            let items = Array(repeating: savedTrack("a"), count: count)
            LibraryProtocol.fixture.reset(.init(data: try savedPage(items, offset: offset, total: Int.max)))
            await #expect(throws: LibraryError.invalidResponse) {
                _ = try await client().savedTracks(offset: offset, limit: 50)
            }
        }
    }
    @Test func savedTracksErrorsAndCancellation() async {
        for (status, error) in [(401, LibraryError.authorizationRequired), (403, .forbidden),
                                 (429, .rateLimited(retryAfterSeconds: 12)), (503, .unavailable), (302, .invalidResponse)] {
            LibraryProtocol.fixture.reset(.init(status: status, headers: ["Retry-After": "12"]))
            await #expect(throws: error) { _ = try await client().savedTracks(offset: 0, limit: 50) }
            #expect(LibraryProtocol.fixture.requests.count == 1)
        }
        LibraryProtocol.fixture.reset(.init(error: URLError(.cancelled)))
        await #expect(throws: CancellationError.self) { _ = try await client().savedTracks(offset: 0, limit: 50) }
    }

    private func scopedClient(_ expected: Set<String>) -> SpotifyLibraryClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LibraryProtocol.self]
        return SpotifyLibraryClient(session: URLSession(configuration: configuration)) { required in
            #expect(required == expected)
            return "TEST_TOKEN"
        }
    }
    private func query(_ request: URLRequest?) -> [URLQueryItem]? {
        request?.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }
    }
    @Test func recentlyPlayedKeepsLoadableContextsAndSkipsBadItems() async throws {
        var album = savedTrack("a")
        album["context"] = ["uri": "spotify:album:alb", "type": "album"]
        var collection = savedTrack("b")
        collection["context"] = ["uri": "spotify:user:someone:collection", "type": "collection"]
        var none = savedTrack("c")
        none["context"] = NSNull()
        let body = try JSONSerialization.data(withJSONObject: ["items": [album, collection, ["track": NSNull()], none]])
        LibraryProtocol.fixture.reset(.init(data: body))
        let plays = try await scopedClient(["user-read-recently-played"]).recentlyPlayed()
        #expect(plays.map(\.track.uri.rawValue) == ["spotify:track:a", "spotify:track:b", "spotify:track:c"])
        #expect(plays.map(\.contextURI?.rawValue) == ["spotify:album:alb", nil, nil])
        let request = LibraryProtocol.fixture.requests.first
        #expect(request?.url?.path == "/v1/me/player/recently-played")
        #expect(query(request) == [URLQueryItem(name: "limit", value: "50")])
    }
    @Test func topItemsAskForFiveMediumTermItemsWithTheTopReadScope() async throws {
        let tracks = try JSONSerialization.data(withJSONObject: ["items": [savedTrack("t")["track"]!, ["uri": 1]]])
        LibraryProtocol.fixture.reset(.init(data: tracks))
        let client = scopedClient(["user-top-read"])
        #expect(try await client.topItems(.tracks) == [StationSeed(uri: SpotifyURI("spotify:track:t")!, name: "Song t")])
        #expect(LibraryProtocol.fixture.requests.first?.url?.path == "/v1/me/top/tracks")
        #expect(query(LibraryProtocol.fixture.requests.first) == [
            URLQueryItem(name: "time_range", value: "medium_term"), URLQueryItem(name: "limit", value: "5")])
        let artists = try JSONSerialization.data(withJSONObject: ["items": [
            ["uri": "spotify:artist:ar", "name": "Artist"], ["uri": "spotify:track:notAnArtist", "name": "X"], ["uri": "spotify:artist:blank", "name": ""]]])
        LibraryProtocol.fixture.reset(.init(data: artists))
        let seeds = try await client.topItems(.artists)
        #expect(seeds == [StationSeed(uri: SpotifyURI("spotify:artist:ar")!, name: "Artist")])
        #expect(seeds.first?.isArtist == true)
        #expect(LibraryProtocol.fixture.requests.first?.url?.path == "/v1/me/top/artists")
    }
    @Test func historyRequestsShareTheLibraryCooldown() async {
        LibraryProtocol.fixture.reset(.init(status: 429, headers: ["Retry-After": "30"]))
        let client = client()
        await #expect(throws: LibraryError.rateLimited(retryAfterSeconds: 30)) { _ = try await client.recentlyPlayed() }
        await #expect(throws: LibraryError.rateLimited(retryAfterSeconds: 30)) { _ = try await client.topItems(.artists) }
        await #expect(throws: LibraryError.rateLimited(retryAfterSeconds: 30)) { _ = try await client.savedTracks(offset: 0, limit: 50) }
        #expect(LibraryProtocol.fixture.requests.count == 1)
    }
    @Test func malformedHistoryResponsesAreInvalid() async {
        LibraryProtocol.fixture.reset(.init(data: Data("{}".utf8)))
        await #expect(throws: LibraryError.invalidResponse) { _ = try await client().recentlyPlayed() }
        await #expect(throws: LibraryError.invalidResponse) { _ = try await client().topItems(.tracks) }
    }
}
