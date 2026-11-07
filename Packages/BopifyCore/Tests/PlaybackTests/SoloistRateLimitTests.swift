import Foundation
import Testing
@testable import BopifyPlayback

private final class RateLimitClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { date } }
    func advance() { lock.withLock { date.addTimeInterval(3601) } }
}
private final class RateLimitHTTPFixture: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var count = 0
    static var requests: Int { lock.withLock { count } }
    static func reset() { lock.withLock { count = 0 } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let count = Self.lock.withLock { Self.count += 1; return Self.count }
        let status = count == 1 ? 429 : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Retry-After": "3600"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"devices":[]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite("Soloist Web API cooldown", .serialized) struct SoloistRateLimitTests {
    @Test func cooldownSurvivesAPIRecreationAndResumesOnlyAfterRetryAfter() async throws {
        RateLimitHTTPFixture.reset()
        let clock = RateLimitClock(), gate = SoloistRateLimit(now: { clock.now })
        func api() -> SoloistWebAPI {
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RateLimitHTTPFixture.self]
            return SoloistWebAPI(session: URLSession(configuration: config), rateLimit: gate)
        }
        let first = api()
        await #expect(throws: SoloistPlaybackError.rateLimited) { _ = try await first.account(token: "fixture") }
        await first.close()
        let next = api()
        await #expect(throws: SoloistPlaybackError.rateLimited) { _ = try await next.devices(token: "fixture") }
        #expect(RateLimitHTTPFixture.requests == 1)
        clock.advance()
        #expect(try await next.devices(token: "fixture").isEmpty)
        #expect(RateLimitHTTPFixture.requests == 2)
        await next.close()
    }
}
