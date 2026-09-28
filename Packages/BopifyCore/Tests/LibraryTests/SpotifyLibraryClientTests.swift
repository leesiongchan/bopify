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
    @Test func statusMappingAndNoRetries() async {
        for (status, error) in [(400, LibraryError.invalidResponse), (401, .authorizationRequired), (403, .forbidden), (429, .rateLimited(retryAfterSeconds: 12)), (500, .unavailable)] {
            LibraryProtocol.fixture.reset(.init(status: status, headers: ["Retry-After": "12"]))
            await #expect(throws: error) { try await client().save(uri) }
            #expect(LibraryProtocol.fixture.requests.count == 1)
        }
    }
    @Test func rateLimitFromLikedSongsBlocksFavoriteRequest() async {
        LibraryProtocol.fixture.reset(.init(status: 429, headers: ["Retry-After": "12"]))
        let client = client()
        await #expect(throws: LibraryError.rateLimited(retryAfterSeconds: 12)) {
            _ = try await client.savedTracks(offset: 0, limit: 50)
        }
        await #expect(throws: LibraryError.rateLimited(retryAfterSeconds: 12)) {
            _ = try await client.savedState(for: uri)
        }
        #expect(LibraryProtocol.fixture.requests.count == 1)
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
        await #expect(throws: LibraryError.rateLimited(retryAfterSeconds: 12)) { _ = try await client.savedState(for: uri) }
        #expect(LibraryProtocol.fixture.requests.isEmpty)
        clock.advance(1)
        #expect(try await client.savedState(for: uri))
        #expect(LibraryProtocol.fixture.requests.count == 1)
    }
    @Test func quotaResponseHasDistinctErrorAndSharedCooldown() async {
        LibraryProtocol.fixture.reset(.init(status: 429,
            data: Data(#"{"error":{"status":429,"message":"Too many requests","reason":"QUOTA_EXCEEDED"}}"#.utf8),
            headers: ["Retry-After": "90"]))
        let client = client()
        await #expect(throws: LibraryError.quotaExceeded(retryAfterSeconds: 90)) { _ = try await client.savedTracks(offset: 0, limit: 50) }
        await #expect(throws: LibraryError.quotaExceeded(retryAfterSeconds: 90)) { _ = try await client.savedState(for: uri) }
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

    private func savedTrack(_ id: String, image: Bool = true) -> [String: Any] {
        ["track": ["uri": "spotify:track:\(id)", "name": "Song \(id)",
                   "artists": [["name": "Artist"]], "duration_ms": 180_000,
                   "album": ["name": "Album", "images": image ? [["url": "https://i.scdn.co/image/cover"]] : []]]]
    }
    private func savedPage(_ items: [Any], offset: Int = 0, total: Int = 7,
                           next: String? = "https://api.spotify.com/v1/me/tracks?offset=3") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["items": items, "offset": offset,
            "limit": 50, "total": total, "next": next as Any? ?? NSNull()])
    }
    @Test func savedTracksRequestUsesReadScope() async throws {
        LibraryProtocol.fixture.reset(.init(data: try savedPage([], total: 0, next: nil)))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LibraryProtocol.self]
        let client = SpotifyLibraryClient(session: URLSession(configuration: configuration)) { required in
            #expect(required == ["user-library-read"])
            return "TEST_TOKEN"
        }
        let page = try await client.savedTracks(offset: 0, limit: 50)
        #expect(page == SavedTracksPage(tracks: [], nextOffset: nil, total: 0))
        let request = try #require(LibraryProtocol.fixture.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.scheme == "https" && request.url?.host == "api.spotify.com")
        #expect(request.url?.path == "/v1/me/tracks")
        #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems == [
            URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "50")])
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
        let items: [Any] = [invalidURI, ["track": negative], ["track": unavailable], ["track": "bad"], savedTrack("ok", image: false)]
        LibraryProtocol.fixture.reset(.init(data: try savedPage(items)))
        let page = try await client().savedTracks(offset: 0, limit: 50)
        #expect(page.tracks.map(\.uri.rawValue) == ["spotify:track:ok"])
        #expect(page.tracks.first?.artwork == nil)
        #expect(page.nextOffset == 5)
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

}
