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
    nonisolated(unsafe) private static var firstBody = Data()
    static var requests: Int { lock.withLock { count } }
    static func reset(body: Data) { lock.withLock { count = 0; firstBody = body } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let (count, body) = Self.lock.withLock { Self.count += 1; return (Self.count, Self.firstBody) }
        let status = count == 1 ? 429 : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Retry-After": "3600"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        finish(body: count == 1 ? body : Data(#"{"devices":[]}"#.utf8))
    }
    private func finish(body: Data) {
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite("Soloist Web API cooldown", .serialized) struct SoloistRateLimitTests {
    @Test(arguments: ["quota", "malformed", "oversized"])
    func cooldownSurvivesAPIRecreationAndResumesOnlyAfterRetryAfter(bodyKind: String) async throws {
        let body = bodyKind == "quota" ? Data(#"{"error":{"reason":"QUOTA_EXCEEDED","message":"private fixture"}}"#.utf8)
            : bodyKind == "malformed" ? Data("not JSON".utf8) : Data(repeating: 32, count: 20_000)
        RateLimitHTTPFixture.reset(body: body)
        let clock = RateLimitClock(), gate = SoloistRateLimit(now: { clock.now })
        func api() -> SoloistWebAPI {
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RateLimitHTTPFixture.self]
            return SoloistWebAPI(session: URLSession(configuration: config), rateLimit: gate)
        }
        let first = api()
        await #expect(throws: SoloistPlaybackError.rateLimited) { _ = try await first.account(token: "fixture") }
        #expect(await gate.retryAt == clock.now.addingTimeInterval(3600))
        await first.close()
        let next = api()
        await #expect(throws: SoloistPlaybackError.rateLimited) { _ = try await next.devices(token: "fixture") }
        #expect(RateLimitHTTPFixture.requests == 1)
        clock.advance()
        #expect(try await next.devices(token: "fixture").isEmpty)
        #expect(RateLimitHTTPFixture.requests == 2)
        await next.close()
    }

    @Test(arguments: ["quota", "unknown", "messageOnly", "malformed", "oversized"])
    func throttleClassificationUsesOnlyBoundedAllowlistedReason(bodyKind: String) throws {
        let bytes: Data
        switch bodyKind {
        case "quota": bytes = Data(#"{"error":{"reason":"QUOTA_EXCEEDED","message":"private fixture"}}"#.utf8)
        case "unknown": bytes = Data(#"{"error":{"reason":"private fixture","message":"QUOTA_EXCEEDED"}}"#.utf8)
        case "messageOnly": bytes = Data(#"{"reason":"QUOTA_EXCEEDED","error":{"message":"QUOTA_EXCEEDED"}}"#.utf8)
        case "oversized": bytes = try JSONSerialization.data(withJSONObject: ["error": ["reason": "QUOTA_EXCEEDED", "message": String(repeating: "x", count: 8192)]])
        default: bytes = Data("private fixture".utf8)
        }
        #expect(SoloistWebAPI.rateLimitClassification(from: bytes) == (bodyKind == "quota" ? "quotaExceeded" : "unspecified"))
    }

    @Test(arguments: [false, true])
    func cooldownIsAppliedBeforeAThrottleBodyFinishes(cancelRequest: Bool) async throws {
        let payload = Data(#"{"error":{"reason":"QUOTA_EXCEEDED"}}"#.utf8)
        RateLimitHTTPFixture.reset(body: payload)
        let clock = RateLimitClock(), gate = SoloistRateLimit(now: { clock.now })
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RateLimitHTTPFixture.self]
        let first = SoloistWebAPI(session: URLSession(configuration: config), rateLimit: gate)
        let next = SoloistWebAPI(session: URLSession(configuration: config), rateLimit: gate)
        let body = AsyncThrowingStream<UInt8, any Error>.makeStream()
        defer { body.continuation.finish() }
        let response = HTTPURLResponse(url: URL(string: "https://api.spotify.com/v1/me")!, statusCode: 429,
            httpVersion: nil, headerFields: ["Retry-After": "3600"])!
        let recording = Task { try await first.recordRateLimit(response: response, bytes: body.stream, operation: "profile") }
        for _ in 0..<100 { if await gate.retryAt > clock.now { break }; try await Task.sleep(for: .milliseconds(10)) }
        #expect(await gate.retryAt == clock.now.addingTimeInterval(3600))
        await #expect(throws: SoloistPlaybackError.rateLimited) { _ = try await next.devices(token: "fixture") }
        #expect(RateLimitHTTPFixture.requests == 0)
        if cancelRequest {
            recording.cancel()
            await #expect(throws: CancellationError.self) { try await recording.value }
            #expect(await gate.retryAt == clock.now.addingTimeInterval(3600))
        } else {
            for byte in payload { body.continuation.yield(byte) }
            body.continuation.finish()
            try await recording.value
        }
        await first.close(); await next.close()
    }
}
