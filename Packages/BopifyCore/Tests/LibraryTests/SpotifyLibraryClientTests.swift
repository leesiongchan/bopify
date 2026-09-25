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

}
