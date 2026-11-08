import Foundation
import Testing
import BopifyDomain
@testable import BopifyPlayback

private final class SoloistChildFixture: SoloistProcessHandle, @unchecked Sendable {
    let endpointURL = URL(string: "ws://127.0.0.1:12345")!
    let diagnosticFailure: SoloistPlaybackError?
    let pairingPort: UInt16?
    private let lock = NSLock()
    private var stops = 0
    private var exited = false
    var stopCount: Int { lock.withLock { stops } }
    var isRunning: Bool { lock.withLock { stops == 0 && !exited } }
    init(diagnosticFailure: SoloistPlaybackError? = nil, pairingPort: UInt16? = nil) {
        self.diagnosticFailure = diagnosticFailure; self.pairingPort = pairingPort
    }
    func stop() async { lock.withLock { stops += 1 } }
    func exit() { lock.withLock { exited = true } }
}

private final class SoloistSocketFixture: SoloistTransport, @unchecked Sendable {
    let pair = AsyncThrowingStream<SoloistFrame, any Error>.makeStream()
    var messages: AsyncThrowingStream<SoloistFrame, any Error> { pair.stream }
    private let lock = NSLock()
    private var sent: [String] = []
    private var frames: [Data] = []
    private var actions = ["pause", "play", "seek"]
    private var shuffle = false
    private var repeatMode = "off"
    let anchor = Date()
    private var uri = "spotify:track:6rqhFgbbKwnb9MLmUQDhG6"
    private var volume: Double = 0
    private var active = true
    private var playbackStatus = "playing"
    private var authenticationReply: Bool?
    private var failsAuthenticationRequest = false
    func setActive(_ value: Bool) { lock.withLock { active = value } }
    func setPlaybackStatus(_ value: String) { lock.withLock { playbackStatus = value } }
    func setAuthenticationReply(_ value: Bool?) { lock.withLock { authenticationReply = value } }
    func failAuthenticationRequests() { lock.withLock { failsAuthenticationRequest = true } }
    var currentURI: String { lock.withLock { uri } }
    func setTrack(_ value: String) { lock.withLock { uri = value } }
    func changeTrack() { lock.withLock { uri = "spotify:track:11dFghVXANMlKmJXsNCbNl" } }
    var position: Double { 1000 + Date().timeIntervalSince(anchor) * 1000 }
    var commands: [String] { lock.withLock { sent } }
    var sentFrames: [Data] { lock.withLock { frames } }
    func setActions(_ values: [String]) { lock.withLock { actions = values } }
    func send(_ data: Data) async throws {
        let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let command = value?["command"] as? String {
            lock.withLock { sent.append(command); frames.append(data) }
            if command == "get_auth_state", lock.withLock({ failsAuthenticationRequest }) {
                throw SoloistPlaybackError.unavailable
            }
            if command == "get_auth_state", let loggedIn = lock.withLock({ authenticationReply }) {
                try emit(["type": "auth_state", "logged_in": loggedIn, "is_active": false])
            }
            if command == "set_volume", let value = value?["volume"] as? Double { lock.withLock { volume = value } }
            if command == "set_shuffle", let enabled = value?["enabled"] as? Bool { lock.withLock { shuffle = enabled } }
            if command == "set_repeat_context", let enabled = value?["enabled"] as? Bool { lock.withLock { repeatMode = enabled ? "context" : "off" } }
            if command == "set_repeat_track", let enabled = value?["enabled"] as? Bool { lock.withLock { repeatMode = enabled ? "track" : "off" } }
            if command == "get_state" {
                try emit(["type": "playback_state", "is_active": lock.withLock { active }, "status": lock.withLock { playbackStatus }, "volume": lock.withLock { volume },
                    "item": ["uri": currentURI, "decorations": ["identity": ["name": "Fixture"], "playback": ["duration_ms": 100000]]],
                    "position": ["position_ms": position, "timestamp_ms": Date().timeIntervalSince1970 * 1000, "speed": 1],
                    "options": lock.withLock { ["shuffle": shuffle, "repeat": repeatMode] as [String: Any] },
                    "available_actions": lock.withLock { Dictionary(uniqueKeysWithValues: actions.map { ($0, [:] as [String: String]) }) }])
            }
        }
    }
    func emit(_ object: [String: Any]) throws {
        pair.continuation.yield(SoloistFrame(data: try JSONSerialization.data(withJSONObject: object), receivedAt: .now))
    }
    func close() async { pair.continuation.finish() }
}

private final class SoloistBatchSocketFixture: SoloistTransport, @unchecked Sendable {
    let pair = AsyncThrowingStream<SoloistFrame, any Error>.makeStream()
    var messages: AsyncThrowingStream<SoloistFrame, any Error> { pair.stream }
    private let lock = NSLock()
    private var sent: [(String, String?)] = []
    private var closed = false
    var observeSelection = true
    var observeSnapshotBeforeTrackEvent = false
    var acknowledge = true
    var sendBootstrapAndUnrelatedAcknowledgement = false
    weak var main: SoloistSocketFixture?
    var commands: [(String, String?)] { lock.withLock { sent } }
    var isClosed: Bool { lock.withLock { closed } }
    func send(_ data: Data) async throws {
        let value = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let command = try #require(value["command"] as? String)
        let uri = value["uri"] as? String
        lock.withLock { sent.append((command, uri)) }
        if command == "play", observeSelection, let uri, let main {
            main.setTrack(uri)
            if observeSnapshotBeforeTrackEvent {
                try await main.send(JSONSerialization.data(withJSONObject: ["command": "get_state"]))
            } else {
                try main.emit(["type": "track_changed", "item": ["uri": uri, "decorations": ["identity": ["name": "Selected"]]]])
            }
        }
        guard acknowledge else { return }
        if sendBootstrapAndUnrelatedAcknowledgement {
            for noise: [String: Any] in [["type": "auth_state", "logged_in": true, "is_active": true],
                                        ["type": "command_result", "command": "pause"]] {
                pair.continuation.yield(SoloistFrame(data: try JSONSerialization.data(withJSONObject: noise), receivedAt: .now))
            }
        }
        let reply: [String: Any] = ["type": "command_result", "command": command]
        pair.continuation.yield(SoloistFrame(data: try JSONSerialization.data(withJSONObject: reply), receivedAt: .now))
    }
    func close() async { lock.withLock { closed = true }; pair.continuation.finish() }
}

private final class SoloistTransportFactoryFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    let main: SoloistSocketFixture
    private var secondary: [any SoloistTransport]
    init(main: SoloistSocketFixture, secondary: (any SoloistTransport)?, additional: [any SoloistTransport]) {
        self.main = main; self.secondary = (secondary.map { [$0] } ?? []) + additional
    }
    func make() -> any SoloistTransport {
        lock.withLock {
            calls += 1
            if calls == 1 { return main }
            return secondary.count > 1 ? secondary.removeFirst() : secondary.first ?? main
        }
    }
}

private final class SoloistHTTPFixture: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var playerStatus: Int?
    nonisolated(unsafe) static var playStatus: Int?
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> Data)?
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requests: [String] = []
    nonisolated(unsafe) private static var writes: [URLRequest] = []
    static var paths: [String] { lock.withLock { requests } }
    static var playRequests: [URLRequest] { lock.withLock { writes } }
    static func reset() { lock.withLock { requests = []; writes = []; playStatus = nil } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let path = request.url?.path ?? ""
        var recorded = request
        if recorded.httpBody == nil, let stream = recorded.httpBodyStream {
            stream.open()
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while data.count < 65_536 {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            stream.close()
            recorded.httpBody = data
        }
        Self.lock.withLock {
            Self.requests.append(path)
            if request.httpMethod == "PUT", path == "/v1/me/player/play" { Self.writes.append(recorded) }
        }
        let data = Self.handler?(request) ?? Data()
        let status = path == "/v1/me/player/play" ? Self.playStatus ?? Self.playerStatus ?? Self.status
            : path.hasPrefix("/v1/me/player") ? Self.playerStatus ?? Self.status : Self.status
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Retry-After": "3600"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private actor SoloistEventFixture {
    var events: [PlaybackEvent] = []
    var statuses: [SoloistEngineStatus] = []
    func append(_ event: PlaybackEvent) { events.append(event) }
    func report(_ status: SoloistEngineStatus) { statuses.append(status) }
}

private actor SoloistPublicationFixture: SoloistPairingPublishing {
    private(set) var isPublished = true
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var canFail = false
    func started() { starts += 1 }
    func releaseFailure() { canFail = true }
    func stop() { isPublished = false; stops += 1 }
}

private final class SoloistPairingTimeFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date()
    private var finished = false
    var didFinish: Bool { lock.withLock { finished } }
    func now() -> Date { lock.withLock { date } }
    func advance(by interval: TimeInterval) { lock.withLock { date.addTimeInterval(interval) } }
    func finish() { lock.withLock { finished = true } }
}

private actor ContinuationIntentFixture {
    private(set) var consents = 0
    private(set) var services = 0
    let changed: Bool
    let holdConsent: Bool
    init(changed: Bool = false, holdConsent: Bool = false) { self.changed = changed; self.holdConsent = holdConsent }
    func authorize() async throws -> Bool {
        consents += 1
        if holdConsent { try await Task.sleep(for: .seconds(100)) }
        return changed
    }
    func makeService() -> any SoloistDataServices { services += 1; return ReadableCompanionFixture() }
}

private func engineFixture(webStatus: Int = 200, diagnosticFailure: SoloistPlaybackError? = nil,
    pairingPort: UInt16? = nil, publisherFactory: SoloistPairingPublisherFactory? = nil,
    webToken: @escaping @Sendable () async throws -> String = { "fixture" },
    streamingToken: @escaping @Sendable () async throws -> String = { "fixture" },
    dataToken: (@Sendable () async throws -> String)? = nil,
    playerStatus: Int? = nil, profile: [String: String]? = nil,
    serviceFactory: @escaping @Sendable (String) async throws -> any SoloistDataServices = { _ in throw PlayerError.networkUnavailable },
    pairingNow: @escaping @Sendable () -> Date = { .now }, authenticationReply: Bool? = nil,
    failsAuthenticationRequest: Bool = false, secondaryTransport: (any SoloistTransport)? = nil,
    followsSocketTrack: Bool = false,
    authorizeContinuation: @escaping @Sendable () async throws -> Bool = { false },
    additionalTransports: [any SoloistTransport] = []) -> (SoloistEngine, SoloistChildFixture, SoloistSocketFixture) {
    let child = SoloistChildFixture(diagnosticFailure: diagnosticFailure, pairingPort: pairingPort), socket = SoloistSocketFixture()
    socket.setAuthenticationReply(authenticationReply)
    if failsAuthenticationRequest { socket.failAuthenticationRequests() }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SoloistHTTPFixture.self]
    SoloistHTTPFixture.status = webStatus
    SoloistHTTPFixture.playerStatus = playerStatus
    SoloistHTTPFixture.reset()
    SoloistHTTPFixture.handler = { request in
        let object: [String: Any]
        if request.url?.path == "/v1/me" {
            let identity = request.value(forHTTPHeaderField: "Authorization") == "Bearer replacement" ? "other-account" : "fixture-account"
            object = profile ?? ["account_id": identity, "id": identity]
        } else if request.url?.path.hasSuffix("devices") == true {
            object = ["devices": [["id": "owned", "name": "Fixture", "is_restricted": false]]]
        } else {
            object = ["device": ["id": "owned", "name": "Fixture"],
                "item": ["uri": followsSocketTrack ? socket.currentURI : "spotify:track:6rqhFgbbKwnb9MLmUQDhG6"], "is_playing": true, "progress_ms": socket.position]
        }
        return try! JSONSerialization.data(withJSONObject: object)
    }
    let transports = SoloistTransportFactoryFixture(main: socket, secondary: secondaryTransport, additional: additionalTransports)
    let engine = SoloistEngine(child: child, api: SoloistWebAPI(session: URLSession(configuration: configuration)), baseline: [], name: "Fixture",
        webToken: webToken, streamingToken: streamingToken,
        transportFactory: { _ in transports.make() }, serviceFactory: { token, expectedUsername in
            let actual = token == "replacement" ? "other-account" : "fixture-account"
            guard actual == expectedUsername else { throw SoloistPlaybackError.accountMismatch }
            return try await serviceFactory(token)
        }, progress: { _ in }, verificationInterval: .milliseconds(600),
        publisherFactory: publisherFactory, dataToken: dataToken, pairingNow: pairingNow, authorizeContinuation: authorizeContinuation)
    return (engine, child, socket)
}


@Suite("Soloist managed engine", .serialized) struct SoloistEngineTests {
private func continuationFixture(_ batch: SoloistBatchSocketFixture, gate: CompanionCreationGate? = nil,
    webToken: @escaping @Sendable () async throws -> String = { "fixture" }) async throws -> (SoloistEngine, SoloistSocketFixture) {
    let (engine, _, socket) = engineFixture(webToken: webToken, serviceFactory: { _ in
        await gate?.wait()
        return ReadableCompanionFixture()
    }, secondaryTransport: batch, followsSocketTrack: true)
    batch.main = socket
    socket.setActions(["play", "pause", "skip_next", "skip_prev", "add_to_queue"])
    await engine.begin()
    try socket.emit(["type": "auth_state", "logged_in": true, "is_active": true])
    try await engine.preparePairing()
    try await engine.adopt(initialVolume: 0.25)
    return (engine, socket)
}

private func waitForPlaybackWrite() async {
    for _ in 0..<400 { if !SoloistHTTPFixture.playRequests.isEmpty { return }; try? await Task.sleep(for: .milliseconds(10)) }
    #expect(!SoloistHTTPFixture.playRequests.isEmpty)
}

@Test(arguments: [false, true])
func exploreContinuationInstallsAReplaceableContextAtTheObservedPosition(restartingSameTrack: Bool) async throws {
    let batch = SoloistBatchSocketFixture(); batch.sendBootstrapAndUnrelatedAcknowledgement = true
    let (engine, _) = try await continuationFixture(batch)
    let selected = SpotifyURI(restartingSameTrack ? "spotify:track:6rqhFgbbKwnb9MLmUQDhG6" : "spotify:track:11dFghVXANMlKmJXsNCbNl")!
    let follower = SpotifyURI(restartingSameTrack ? "spotify:track:11dFghVXANMlKmJXsNCbNl" : "spotify:track:6rqhFgbbKwnb9MLmUQDhG6")!
    try await engine.load(PlayRequest(contextURI: selected, followingTrackURIs: [selected, follower, follower]))
    await waitForPlaybackWrite()
    let write = try #require(SoloistHTTPFixture.playRequests.first)
    let bytes = try #require(write.httpBody), url = try #require(write.url)
    let body = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    #expect(body["uris"] as? [String] == [selected.rawValue, follower.rawValue])
    #expect((body["position_ms"] as? Double ?? 0) > 0)
    #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "device_id", value: "owned")])
    #expect(batch.commands.map(\.0) == ["play"], "Recommendations belong to a replaceable context, never the manual queue")
    #expect(batch.isClosed)
    await engine.shutdown()
}

@Test func exploreContinuationWaitsForTheGranularSelectionEventAfterItsSnapshot() async throws {
    let batch = SoloistBatchSocketFixture(); batch.observeSnapshotBeforeTrackEvent = true
    let (engine, socket) = try await continuationFixture(batch)
    let selected = SpotifyURI("spotify:track:11dFghVXANMlKmJXsNCbNl")!
    let finished = SoloistPairingTimeFixture()
    let loading = Task {
        try await engine.load(PlayRequest(contextURI: selected, followingTrackURIs: [SpotifyURI("spotify:track:4uLU6hMCjMI75M1A2tKUQC")!]))
        finished.finish()
    }
    for _ in 0..<100 { if !batch.commands.isEmpty { break }; try await Task.sleep(for: .milliseconds(5)) }
    try await Task.sleep(for: .milliseconds(50))
    #expect(!finished.didFinish)
    #expect(SoloistHTTPFixture.playRequests.isEmpty)
    try socket.emit(["type": "track_changed", "item": ["uri": selected.rawValue,
        "decorations": ["identity": ["name": "Fixture"], "playback": ["duration_ms": 100000]]]])
    try await loading.value
    await waitForPlaybackWrite()
    #expect(batch.isClosed)
    await engine.shutdown()
}

@Test func exploreReselectionReplacesItsPreviousAutomaticContext() async throws {
    let first = SoloistBatchSocketFixture(), second = SoloistBatchSocketFixture()
    let (engine, _, socket) = engineFixture(serviceFactory: { _ in ReadableCompanionFixture() },
        secondaryTransport: first, followsSocketTrack: true, additionalTransports: [second])
    first.main = socket; second.main = socket
    socket.setActions(["play", "pause", "add_to_queue"])
    await engine.begin(); try socket.emit(["type": "auth_state", "logged_in": true, "is_active": true])
    try await engine.preparePairing(); try await engine.adopt(initialVolume: 0.25)
    let a = SpotifyURI("spotify:track:11dFghVXANMlKmJXsNCbNl")!, b = SpotifyURI("spotify:track:6rqhFgbbKwnb9MLmUQDhG6")!
    let c = SpotifyURI("spotify:track:4uLU6hMCjMI75M1A2tKUQC")!, d = SpotifyURI("spotify:track:next")!
    try await engine.load(PlayRequest(contextURI: a, followingTrackURIs: [b, c]))
    await waitForPlaybackWrite()
    try await engine.load(PlayRequest(contextURI: c, followingTrackURIs: [d]))
    for _ in 0..<400 { if SoloistHTTPFixture.playRequests.count == 2 { break }; try await Task.sleep(for: .milliseconds(10)) }
    let writes = SoloistHTTPFixture.playRequests
    try #require(writes.count == 2)
    let firstBytes = try #require(writes[0].httpBody), secondBytes = try #require(writes[1].httpBody)
    let oldContext = try #require(try JSONSerialization.jsonObject(with: firstBytes) as? [String: Any])
    let newContext = try #require(try JSONSerialization.jsonObject(with: secondBytes) as? [String: Any])
    #expect(oldContext["uris"] as? [String] == [a.rawValue, b.rawValue, c.rawValue])
    #expect(newContext["uris"] as? [String] == [c.rawValue, d.rawValue])
    #expect((first.commands + second.commands).allSatisfy { $0.0 == "play" })
    await engine.shutdown()
}

@Test(arguments: ["noConfirmation", "sameSongWithoutOccurrence", "missingAcknowledgement"])
func exploreContinuationNeverInstallsWithoutPlaybackAndCommandConfirmation(mode: String) async throws {
    let batch = SoloistBatchSocketFixture(); batch.observeSelection = false
    if mode == "missingAcknowledgement" { batch.acknowledge = false }
    let (engine, _) = try await continuationFixture(batch)
    let selected = SpotifyURI(mode == "sameSongWithoutOccurrence" ? "spotify:track:6rqhFgbbKwnb9MLmUQDhG6" : "spotify:track:11dFghVXANMlKmJXsNCbNl")!
    await #expect(throws: SoloistPlaybackError.self) {
        try await engine.load(PlayRequest(contextURI: selected, followingTrackURIs: [SpotifyURI("spotify:track:4uLU6hMCjMI75M1A2tKUQC")!]))
    }
    #expect(SoloistHTTPFixture.playRequests.isEmpty)
    #expect(batch.isClosed)
    await engine.shutdown()
}

@Test(arguments: ["pause", "next", "newLoad", "ownership", "authentication", "otherTrack", "sameTrack", "socketLost", "shutdown"])
func explorePendingContextDoesNotBlockControlsAndStopsWithItsOccurrence(interruption: String) async throws {
    let batch = SoloistBatchSocketFixture(), gate = CompanionCreationGate()
    let (engine, socket) = try await continuationFixture(batch, gate: gate)
    let selected = SpotifyURI("spotify:track:11dFghVXANMlKmJXsNCbNl")!
    let follower = SpotifyURI("spotify:track:4uLU6hMCjMI75M1A2tKUQC")!
    try await engine.load(PlayRequest(contextURI: selected, followingTrackURIs: [follower]))
    switch interruption {
    case "pause": try await engine.pause()
    case "next": try await engine.next()
    case "newLoad": try await engine.load(PlayRequest(contextURI: follower))
    case "ownership": try socket.emit(["type": "device_changed", "is_active": false])
    case "authentication": try socket.emit(["type": "auth_state", "logged_in": false, "is_active": false])
    case "otherTrack", "sameTrack":
        try socket.emit(["type": "track_changed", "item": ["uri": interruption == "sameTrack" ? selected.rawValue : follower.rawValue,
            "decorations": ["identity": ["name": "Another occurrence"]]]])
    case "socketLost": await socket.close()
    default: break
    }
    await gate.release()
    if interruption == "shutdown" { await engine.shutdown() }
    else { try await Task.sleep(for: .milliseconds(800)); await engine.shutdown() }
    #expect(SoloistHTTPFixture.playRequests.isEmpty)
    #expect(batch.isClosed)
}

@Test(arguments: ["rejected", "rateLimited", "expired"])
func exploreContextFailureIsVisibleAndNeverFallsBackToManualQueue(failure: String) async throws {
    let batch = SoloistBatchSocketFixture(), gate = CompanionCreationGate(), expired = SoloistPairingTimeFixture()
    let (engine, _) = try await continuationFixture(batch, gate: gate, webToken: {
        if expired.didFinish { throw PlayerError.authExpired }; return "fixture"
    })
    if failure == "rejected" { SoloistHTTPFixture.playStatus = 403 }
    if failure == "rateLimited" { SoloistHTTPFixture.playStatus = 429 }
    let observations = SoloistEventFixture()
    let reader = Task { for await event in engine.events { await observations.append(event) } }
    try await engine.load(PlayRequest(contextURI: SpotifyURI("spotify:track:11dFghVXANMlKmJXsNCbNl")!,
        followingTrackURIs: [SpotifyURI("spotify:track:4uLU6hMCjMI75M1A2tKUQC")!]))
    if failure == "expired" { expired.finish() }
    await gate.release()
    for _ in 0..<1200 {
        if await observations.events.contains(.commandRejected("unavailable")) { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await observations.events.contains(.commandRejected("unavailable")))
    #expect(!batch.commands.contains { $0.0 == "add_to_queue" })
    if failure == "expired" { #expect(SoloistHTTPFixture.playRequests.isEmpty) }
    await engine.shutdown(); await reader.value
}

@Test(arguments: ["tooMany", "nonTrack", "context", "offset"])
func exploreContinuationValidatesEverythingBeforePlayback(invalid: String) async throws {
    let batch = SoloistBatchSocketFixture()
    let (engine, _) = try await continuationFixture(batch)
    let selected = SpotifyURI("spotify:track:11dFghVXANMlKmJXsNCbNl")!
    let follower = SpotifyURI("spotify:track:4uLU6hMCjMI75M1A2tKUQC")!
    let request = PlayRequest(contextURI: invalid == "context" ? SpotifyURI("spotify:album:4aawyAB9vmqN3uQ7FjRGTy")! : selected,
        startPositionMs: invalid == "offset" ? 1000 : 0,
        followingTrackURIs: invalid == "tooMany" ? Array(repeating: follower, count: 51)
            : [invalid == "nonTrack" ? SpotifyURI("spotify:episode:fixture")! : follower])
    await #expect(throws: SoloistPlaybackError.self) { try await engine.load(request) }
    #expect(batch.commands.isEmpty)
    #expect(SoloistHTTPFixture.playRequests.isEmpty)
    await engine.shutdown()
}

@Test func exploreConsentIsIntentOnlyAndChangedGrantsEstablishFreshProof() async throws {
    let intent = ContinuationIntentFixture(changed: true), batch = SoloistBatchSocketFixture()
    let (engine, _, socket) = engineFixture(serviceFactory: { _ in await intent.makeService() },
        secondaryTransport: batch, followsSocketTrack: true, authorizeContinuation: { try await intent.authorize() })
    batch.main = socket; socket.setActions(["play", "pause", "add_to_queue"])
    await engine.begin(); try socket.emit(["type": "auth_state", "logged_in": true, "is_active": true])
    try await engine.preparePairing(); try await engine.adopt(initialVolume: 0.25)
    await engine.retryDataServices()
    try await engine.load(PlayRequest(contextURI: SpotifyURI("spotify:track:6rqhFgbbKwnb9MLmUQDhG6")!))
    #expect(await intent.consents == 0)
    try await engine.load(PlayRequest(contextURI: SpotifyURI("spotify:track:11dFghVXANMlKmJXsNCbNl")!,
        followingTrackURIs: [SpotifyURI("spotify:track:4uLU6hMCjMI75M1A2tKUQC")!]))
    await waitForPlaybackWrite()
    #expect(await intent.consents == 1)
    #expect(await intent.services >= 2)
    await engine.shutdown()
}

@Test func exploreConsentCancellationCannotBlockPauseOrInstallAContext() async throws {
    let intent = ContinuationIntentFixture(holdConsent: true), batch = SoloistBatchSocketFixture()
    let (engine, _, socket) = engineFixture(serviceFactory: { _ in await intent.makeService() },
        secondaryTransport: batch, followsSocketTrack: true, authorizeContinuation: { try await intent.authorize() })
    batch.main = socket; socket.setActions(["play", "pause", "add_to_queue"])
    await engine.begin(); try socket.emit(["type": "auth_state", "logged_in": true, "is_active": true])
    try await engine.preparePairing(); try await engine.adopt(initialVolume: 0.25)
    try await engine.load(PlayRequest(contextURI: SpotifyURI("spotify:track:11dFghVXANMlKmJXsNCbNl")!,
        followingTrackURIs: [SpotifyURI("spotify:track:4uLU6hMCjMI75M1A2tKUQC")!]))
    for _ in 0..<100 { if await intent.consents > 0 { break }; try await Task.sleep(for: .milliseconds(5)) }
    #expect(await intent.consents == 1)
    try await engine.pause()
    #expect(socket.commands.contains("pause"))
    #expect(SoloistHTTPFixture.playRequests.isEmpty)
    await engine.shutdown()
}

@Test func exploreConcurrentShutdownJoinsContextCleanupOnlyOnce() async throws {
    let intent = ContinuationIntentFixture(holdConsent: true), batch = SoloistBatchSocketFixture()
    let (engine, child, socket) = engineFixture(serviceFactory: { _ in await intent.makeService() },
        secondaryTransport: batch, followsSocketTrack: true, authorizeContinuation: { try await intent.authorize() })
    batch.main = socket; socket.setActions(["play", "pause", "add_to_queue"])
    await engine.begin(); try socket.emit(["type": "auth_state", "logged_in": true, "is_active": true])
    try await engine.preparePairing(); try await engine.adopt(initialVolume: 0.25)
    try await engine.load(PlayRequest(contextURI: SpotifyURI("spotify:track:11dFghVXANMlKmJXsNCbNl")!,
        followingTrackURIs: [SpotifyURI("spotify:track:4uLU6hMCjMI75M1A2tKUQC")!]))
    for _ in 0..<100 { if await intent.consents > 0 { break }; try await Task.sleep(for: .milliseconds(5)) }
    async let first: Void = engine.shutdown()
    async let second: Void = engine.shutdown()
    _ = await (first, second)
    #expect(child.stopCount == 1)
    #expect(batch.isClosed)
    #expect(SoloistHTTPFixture.playRequests.isEmpty)
}

@Test(arguments: [false, true])
func publishedPairingWaitsPastFiveMinutesUntilCancellationOrChildFailure(childFails: Bool) async throws {
    let time = SoloistPairingTimeFixture()
    let publication = SoloistPublicationFixture()
    let (engine, child, socket) = engineFixture(pairingPort: 1234, publisherFactory: { _, _ in
        await publication.started()
        return publication
    }, pairingNow: { time.now() })
    await engine.begin()
    try socket.emit(["type": "auth_state", "logged_in": false, "is_active": false])
    let preparation = Task {
        defer { time.finish() }
        try await engine.preparePairing()
    }
    for _ in 0..<100 {
        if await publication.starts == 1 { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await publication.starts == 1)
    time.advance(by: 301)
    try await Task.sleep(for: .milliseconds(350))
    #expect(!time.didFinish, "A discoverable device must keep waiting while the person completes Spotify setup")
    #expect(await publication.isPublished && child.isRunning)
    if childFails { child.exit() } else { preparation.cancel() }
    let result = await preparation.result
    await engine.shutdown()
    if childFails {
        #expect(throws: SoloistPlaybackError.startupFailed) { try result.get() }
    } else {
        #expect(throws: CancellationError.self) { try result.get() }
    }
    #expect(await publication.stops == 1 && child.stopCount == 1)
}

@Test func connectionRequestsAuthenticationBeforeWaitingForDiscovery() async throws {
    let publication = SoloistPublicationFixture()
    let (engine, child, socket) = engineFixture(pairingPort: 1234, publisherFactory: { _, _ in
        await publication.started()
        return publication
    }, authenticationReply: false)
    await engine.begin()
    let preparation = Task { try await engine.preparePairing() }
    for _ in 0..<100 {
        if await publication.starts == 1 { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await publication.starts == 1, "Discovery must not depend on an unsolicited initial auth event")
    #expect(socket.commands == ["get_auth_state"])
    #expect(await !engine.isPaired && child.isRunning)
    preparation.cancel()
    _ = await preparation.result
    await engine.shutdown()
    #expect(await publication.stops == 1 && child.stopCount == 1)
}

@Test func failedAuthenticationBootstrapKeepsTheChildForConnectionRecovery() async throws {
    let (engine, child, socket) = engineFixture(failsAuthenticationRequest: true)
    await engine.begin()
    for _ in 0..<100 {
        if await !engine.isConnected { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(socket.commands.contains("get_auth_state"))
    #expect(await !engine.isConnected)
    #expect(await !engine.isPaired)
    #expect(child.isRunning && child.stopCount == 0)
    #expect(!socket.commands.contains("play") && !socket.commands.contains("activate"))
    await engine.shutdown()
    #expect(child.stopCount == 1)
}

@Test func completedPairingSurvivesAConcurrentBonjourFailure() async throws {
    let publication = SoloistPublicationFixture()
    let (engine, _, socket) = engineFixture(pairingPort: 1234, publisherFactory: { _, _ in
        await publication.started()
        while !(await publication.canFail) { try await Task.sleep(for: .milliseconds(5)) }
        throw SoloistPlaybackError.discoveryUnavailable
    })
    await engine.begin()
    try socket.emit(["type": "auth_state", "logged_in": false, "is_active": false])
    let preparation = Task { try await engine.preparePairing() }
    for _ in 0..<100 {
        if await publication.starts == 1 { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await publication.starts == 1)
    try socket.emit(["type": "auth_state", "logged_in": true, "is_active": true])
    for _ in 0..<10000 { if await engine.isPaired { break }; await Task.yield() }
    #expect(await engine.isPaired)
    await publication.releaseFailure()
    let result = await preparation.result
    await engine.shutdown()
    try result.get()
}

@Test func nativePublicationReplacesFailedSDKMulticastAndStopsWithItsChild() async throws {
    let publication = SoloistPublicationFixture()
    let (engine, child, socket) = engineFixture(diagnosticFailure: .discoveryUnavailable, pairingPort: 1234,
        publisherFactory: { port, name in
            #expect(port == 1234 && name == "Fixture")
            await publication.started()
            return publication
        })
    await engine.begin()
    try socket.emit(["type": "auth_state", "logged_in": false, "is_active": false])
    let preparation = Task { try await engine.preparePairing() }
    for _ in 0..<100 {
        if await publication.starts == 1 { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await publication.starts == 1)
    try socket.emit(["type": "auth_state", "logged_in": true, "is_active": true])
    try await preparation.value
    #expect(await publication.isPublished)
    await engine.shutdown()
    #expect(await publication.stops == 1 && child.stopCount == 1)
}

@Test(arguments: [SoloistPlaybackError.invalidKey, .discoveryUnavailable])
func unpairedSetupSurfacesSDKDiagnosticFailure(failure: SoloistPlaybackError) async throws {
    let (engine, _, socket) = engineFixture(diagnosticFailure: failure)
    await engine.begin()
    try socket.emit(["type": "auth_state", "logged_in": false, "is_active": false])
    let prepare = Task { try await engine.preparePairing() }
    let timeout = Task {
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
        prepare.cancel()
    }
    await #expect(throws: failure) { try await prepare.value }
    timeout.cancel()
    await engine.shutdown()
}

@Test func discoveryFailureWaitsForTheInitialRestoredAuthenticationState() async throws {
    let (engine, _, socket) = engineFixture(diagnosticFailure: .discoveryUnavailable)
    await engine.begin()
    let prepare = Task { try await engine.preparePairing() }
    try await Task.sleep(for: .milliseconds(20))
    try socket.emit(["type": "auth_state", "logged_in": true, "is_active": true])
    let outcome = await prepare.result
    await engine.shutdown()
    try outcome.get()
}

@Test func restoredPairedAudioIgnoresDiscoveryDiagnosticFailure() async throws {
    let (engine, child, socket) = engineFixture(diagnosticFailure: .discoveryUnavailable, publisherFactory: { _, _ in
        Issue.record("A restored paired session must not wait for LAN publication")
        throw SoloistPlaybackError.discoveryUnavailable
    })
    await engine.begin()
    try socket.emit(["type": "auth_state", "logged_in": true, "is_active": true])
    for _ in 0..<10000 { if await engine.isPaired { break }; await Task.yield() }
    try #require(await engine.isPaired)
    try await engine.preparePairing()
    #expect(child.isRunning)
    await engine.shutdown()
}

@Test func localSoloistRemainsReadyWhenSpotifyWebAccessIsThrottled() async throws {
    let (engine, child, socket) = engineFixture(webStatus: 429)
    await engine.begin()
    try socket.emit(["type": "auth_state", "logged_in": true, "is_active": true])
    try await engine.preparePairing()
    try await engine.adopt(initialVolume: 0.25)
    try await engine.pause()
    #expect(socket.commands.contains("pause") && child.isRunning)
    let uri = SpotifyURI("spotify:track:6rqhFgbbKwnb9MLmUQDhG6")!
    try await engine.load(PlayRequest(contextURI: uri))
    #expect(socket.commands.contains("play"))
    await #expect(throws: LyricFailure.unavailable) { try await engine.requestLyrics(for: uri) }
    await engine.shutdown()
}

@Test func inactivePairedSoloistCanBeTheDefaultWithoutAutoplayOrWebAccess() async throws {
    let (engine, child, socket) = engineFixture(webToken: { Issue.record("Inactive Core must not request playback scope"); throw SoloistPlaybackError.rateLimited },
        dataToken: { "fixture" })
    socket.setActive(false)
    let observations = SoloistEventFixture()
    let reader = Task { for await event in engine.events { await observations.append(event) } }
    await engine.begin()
    try socket.emit(["type": "auth_state", "logged_in": true, "is_active": false])
    try await engine.preparePairing()
    try await engine.adopt(initialVolume: 0.25)
    #expect(!socket.commands.contains("play") && !socket.commands.contains("activate"))
    await engine.shutdown(); await reader.value
    #expect(await observations.events.contains(.connectionReady(.remote)))
    #expect(child.stopCount == 1)
}

// A metadata-only companion has no audio or Connect control. Its account proof
// must work before playback; device correlation remains a Web playback gate.
@Test func metadataNeverUsesTheStreamingTokenForWebAPIProfiles() async throws {
    let service = ReadableCompanionFixture()
    let (engine, _, socket) = engineFixture(streamingToken: { "streaming-only" }, dataToken: { "fixture" },
        serviceFactory: { _ in service })
    SoloistHTTPFixture.handler = { request in
        guard request.value(forHTTPHeaderField: "Authorization") != "Bearer streaming-only" else {
            return Data(#"{"error":{"reason":"QUOTA_EXCEEDED"}}"#.utf8)
        }
        return Data(#"{"account_id":"fixture-account","id":"fixture-account"}"#.utf8)
    }
    socket.setPlaybackStatus("idle")
    await engine.begin()
    try socket.emit(["type": "auth_state", "logged_in": true, "is_active": true])
    try await engine.preparePairing(); try await engine.adopt(initialVolume: 0.25)
    defer { Task { await engine.shutdown() } }
    let track = SpotifyURI("spotify:track:6rqhFgbbKwnb9MLmUQDhG6")!
    let lyrics = try await engine.requestLyrics(for: track)
    #expect(lyrics.lines.map(\.text) == ["Fixture lyric"])
    #expect(await service.requests == 1)
}

@Test func metadataRequestsWaitForAccountProofAndRemainGatedAfterLogout() async throws {
    let service = CompanionServiceFixture()
    let (engine, _, socket) = engineFixture(serviceFactory: { _ in service })
    await engine.begin()
    try socket.emit(["type": "auth_state", "logged_in": true, "is_active": true])
    try await engine.preparePairing()
    try await engine.adopt(initialVolume: 0.25)
    let uri = SpotifyURI("spotify:track:6rqhFgbbKwnb9MLmUQDhG6")!
    await #expect(throws: LyricFailure.unavailable) { try await engine.requestLyrics(for: uri) }
    #expect(await service.lyricRequests == 1)
    await engine.retryDataServices()
    await #expect(throws: LyricFailure.unavailable) { try await engine.requestLyrics(for: uri) }
    #expect(await service.lyricRequests == 2)
    try socket.emit(["type": "auth_state", "logged_in": false, "is_active": false])
    for _ in 0..<1000 { if await !engine.isPaired { break }; await Task.yield() }
    await #expect(throws: LyricFailure.unavailable) { try await engine.requestLyrics(for: uri) }
    #expect(await service.lyricRequests == 2)
    await engine.shutdown()
}

@Test(arguments: ["idle", "paused", "inactive"])
func metadataWorksBeforePlaybackWithoutPlaybackScope(state: String) async throws {
    let service = ReadableCompanionFixture()
    let (engine, _, socket) = engineFixture(webToken: { throw SoloistPlaybackError.authorizationRequired },
        dataToken: { "fixture" }, serviceFactory: { _ in service })
    socket.setPlaybackStatus(state == "inactive" ? "playing" : state)
    socket.setActive(state != "inactive")
    await engine.begin()
    try socket.emit(["type": "auth_state", "logged_in": true, "is_active": state != "inactive"])
    try await engine.preparePairing(); try await engine.adopt(initialVolume: 0.25)
    let track = SpotifyURI("spotify:track:6rqhFgbbKwnb9MLmUQDhG6")!
    let radio = try await engine.requestRadio(seed: track)
    let lyrics = try await engine.requestLyrics(for: track)
    let artist = try await engine.requestArtistTopTracks(for: track, artistIndex: 0)
    #expect(radio.contextURI.rawValue == "spotify:playlist:fixture")
    #expect(lyrics.lines.map(\.text) == ["Fixture lyric"])
    #expect(artist.trackURI == track)
    #expect(!SoloistHTTPFixture.paths.contains { $0.hasPrefix("/v1/me/player") })
    #expect(!socket.commands.contains("play") && !socket.commands.contains("activate"))
    await engine.shutdown()
}

@Test func simultaneousMetadataRequestsJoinTheInitialSessionWarmup() async throws {
    let service = ReadableCompanionFixture(), creation = CompanionCreationGate()
    let (engine, _, socket) = engineFixture(dataToken: { "fixture" }, serviceFactory: { _ in
        await creation.wait(); return service
    })
    socket.setPlaybackStatus("idle")
    await engine.begin()
    try socket.emit(["type": "auth_state", "logged_in": true, "is_active": true])
    try await engine.preparePairing(); try await engine.adopt(initialVolume: 0.25)
    let track = SpotifyURI("spotify:track:6rqhFgbbKwnb9MLmUQDhG6")!
    let requests = Task {
        async let radio = engine.requestRadio(seed: track)
        async let lyrics = engine.requestLyrics(for: track)
        async let artist = engine.requestArtistTopTracks(for: track, artistIndex: 0)
        return try await (radio, lyrics, artist)
    }
    for _ in 0..<100 { if await creation.starts > 0 { break }; try await Task.sleep(for: .milliseconds(10)) }
    #expect(await creation.starts == 1)
    await creation.release()
    let outcome = await requests.result
    await engine.shutdown()
    let (radio, lyrics, artist) = try outcome.get()
    #expect(radio.contextURI.rawValue == "spotify:playlist:fixture")
    #expect(lyrics.trackURI == track && artist.trackURI == track)
    #expect(await creation.starts == 1)
}

@Test func optionalPlaybackRateLimitDoesNotRevokeMetadata() async throws {
    let service = ReadableCompanionFixture()
    let (engine, child, socket) = engineFixture(dataToken: { "fixture" }, playerStatus: 429, serviceFactory: { _ in service })
    await engine.begin()
    try socket.emit(["type": "auth_state", "logged_in": true, "is_active": true])
    try await engine.preparePairing(); try await engine.adopt(initialVolume: 0.25)
    await engine.retryDataServices()
    let track = SpotifyURI("spotify:track:6rqhFgbbKwnb9MLmUQDhG6")!
    let radio = try await engine.requestRadio(seed: track)
    #expect(radio.contextURI.rawValue == "spotify:playlist:fixture")
    #expect(SoloistHTTPFixture.paths.contains("/v1/me/player"))
    await #expect(throws: SoloistPlaybackError.pairingRequired) {
        try await engine.load(PlayRequest(contextURI: track, startPositionMs: 1000))
    }
    #expect(await service.shutdowns == 0 && child.isRunning)
    await engine.shutdown()
}

@Test func changingTheOptionalPlaybackGrantRevokesRemoteObservationButKeepsMetadata() async throws {
    let token = ServiceTokenFixture(), service = ReadableCompanionFixture()
    let (engine, _, socket) = engineFixture(webToken: { token.value }, dataToken: { "fixture" }, serviceFactory: { _ in service })
    await engine.begin()
    try socket.emit(["type": "auth_state", "logged_in": true, "is_active": true])
    try await engine.preparePairing(); try await engine.adopt(initialVolume: 0.25)
    await engine.retryDataServices()
    let track = SpotifyURI("spotify:track:6rqhFgbbKwnb9MLmUQDhG6")!
    try await engine.load(PlayRequest(contextURI: track, startPositionMs: 1000))
    let before = SoloistHTTPFixture.paths.filter { $0 == "/v1/me/player" }.count
    token.replace()
    socket.setActive(false)
    for _ in 0..<35 { await engine.poll(); await Task.yield() }
    #expect(SoloistHTTPFixture.paths.filter { $0 == "/v1/me/player" }.count == before)
    let radio = try await engine.requestRadio(seed: track)
    #expect(radio.contextURI.rawValue == "spotify:playlist:fixture")
    #expect(await service.shutdowns == 0)
    await engine.shutdown()
}

@Test(arguments: [["id": "legacy-only"], ["account_id": ""]])
func metadataIdentityNeverSubstitutesALegacyUsername(profile: [String: String]) async throws {
    let creation = CompanionCreationGate(), service = ReadableCompanionFixture()
    await creation.release()
    let (engine, _, socket) = engineFixture(dataToken: { "fixture" }, profile: profile, serviceFactory: { _ in
        await creation.wait(); return service
    })
    socket.setPlaybackStatus("idle")
    await engine.begin()
    try socket.emit(["type": "auth_state", "logged_in": true, "is_active": true])
    try await engine.preparePairing(); try await engine.adopt(initialVolume: 0.25)
    await #expect(throws: RadioFailure.unavailable) { _ = try await engine.requestRadio(seed: SpotifyURI("spotify:track:fixture")!) }
    #expect(await creation.starts == 0)
    await engine.shutdown()
}

@Test func mismatchedLibraryAndStreamingAccountsCannotCreateMetadataSession() async throws {
    let creation = CompanionCreationGate(), service = ReadableCompanionFixture()
    await creation.release()
    let (engine, _, socket) = engineFixture(dataToken: { "replacement" }, serviceFactory: { _ in
        await creation.wait(); return service
    })
    socket.setPlaybackStatus("idle")
    await engine.begin()
    try socket.emit(["type": "auth_state", "logged_in": true, "is_active": true])
    try await engine.preparePairing(); try await engine.adopt(initialVolume: 0.25)
    await #expect(throws: RadioFailure.unavailable) { _ = try await engine.requestRadio(seed: SpotifyURI("spotify:track:fixture")!) }
    #expect(await creation.starts == 0)
    await engine.shutdown()
}

@Test(arguments: ["radio", "lyrics", "artist"], ["library", "streaming"])
func metadataReplyCannotOutliveCredentialReplacement(operation: String, credential: String) async throws {
    let gate = CompanionCreationGate(), token = ServiceTokenFixture(), service = ReadableCompanionFixture()
    await service.hold(on: gate)
    let (engine, _, socket) = engineFixture(streamingToken: { credential == "streaming" ? token.value : "fixture" },
        dataToken: { credential == "library" ? token.value : "fixture" }, serviceFactory: { _ in service })
    socket.setPlaybackStatus("idle")
    await engine.begin()
    try socket.emit(["type": "auth_state", "logged_in": true, "is_active": true])
    try await engine.preparePairing(); try await engine.adopt(initialVolume: 0.25)
    let request = Task { try await metadataRequest(operation, engine: engine) }
    for _ in 0..<100 { if await gate.starts > 0 { break }; try await Task.sleep(for: .milliseconds(10)) }
    #expect(await gate.starts == 1)
    token.replace()
    await gate.release()
    await expectUnavailable(request, operation: operation)
    #expect(await service.shutdowns > 0)
    await engine.shutdown()
}

@Test(arguments: ["radio", "lyrics", "artist"])
func metadataReplyCannotOutliveAuthorizationSuspension(operation: String) async throws {
    let gate = CompanionCreationGate(), service = ReadableCompanionFixture()
    await service.hold(on: gate)
    let (engine, _, socket) = engineFixture(dataToken: { "fixture" }, serviceFactory: { _ in service })
    socket.setPlaybackStatus("idle")
    await engine.begin()
    try socket.emit(["type": "auth_state", "logged_in": true, "is_active": true])
    try await engine.preparePairing(); try await engine.adopt(initialVolume: 0.25)
    let request = Task { try await metadataRequest(operation, engine: engine) }
    for _ in 0..<100 { if await gate.starts > 0 { break }; try await Task.sleep(for: .milliseconds(10)) }
    #expect(await gate.starts == 1)
    await engine.suspendDataServices()
    await gate.release()
    await expectUnavailable(request, operation: operation)
    #expect(await service.shutdowns > 0)
    await engine.shutdown()
}

@Test func aMetadataSessionCreatedAfterSuspensionIsDestroyedWithoutPublication() async throws {
    let gate = CompanionCreationGate(), service = ReadableCompanionFixture()
    let (engine, _, socket) = engineFixture(dataToken: { "fixture" }, serviceFactory: { _ in await gate.wait(); return service })
    socket.setPlaybackStatus("idle")
    await engine.begin()
    try socket.emit(["type": "auth_state", "logged_in": true, "is_active": true])
    try await engine.preparePairing(); try await engine.adopt(initialVolume: 0.25)
    let request = Task { try await metadataRequest("radio", engine: engine) }
    for _ in 0..<100 { if await gate.starts > 0 { break }; try await Task.sleep(for: .milliseconds(10)) }
    #expect(await gate.starts == 1)
    let suspension = Task { await engine.suspendDataServices() }
    for _ in 0..<100 { await Task.yield() }
    await gate.release()
    await suspension.value
    await expectUnavailable(request, operation: "radio")
    #expect(await service.shutdowns > 0)
    #expect(await service.requests == 0)
    await engine.shutdown()
}

@Test func replacingAStreamingGrantCannotReuseThePreviousAccountsCachedServices() async throws {
    let token = ServiceTokenFixture(), service = CompanionServiceFixture()
    let (engine, _, socket) = engineFixture(streamingToken: { token.value }, serviceFactory: { _ in service })
    await engine.begin()
    try socket.emit(["type": "auth_state", "logged_in": true, "is_active": true])
    try await engine.preparePairing(); try await engine.adopt(initialVolume: 0.25)
    await engine.retryDataServices()
    let uri = SpotifyURI("spotify:track:6rqhFgbbKwnb9MLmUQDhG6")!
    await #expect(throws: LyricFailure.unavailable) { try await engine.requestLyrics(for: uri) }
    #expect(await service.lyricRequests == 1)
    token.replace()
    await #expect(throws: LyricFailure.unavailable) { try await engine.requestLyrics(for: uri) }
    #expect(await service.lyricRequests == 1, "A replacement credential must revoke cached companion access")
    try await engine.pause()
    await engine.shutdown()
}

@Test func reauthorizingServicesRevokesAssistedLoadsWithoutStoppingLocalCore() async throws {
    let token = ServiceTokenFixture(), service = CompanionServiceFixture()
    let (engine, child, socket) = engineFixture(webToken: { token.value }, serviceFactory: { _ in service })
    await engine.begin()
    try socket.emit(["type": "auth_state", "logged_in": true, "is_active": true])
    try await engine.preparePairing(); try await engine.adopt(initialVolume: 0.25)
    await engine.retryDataServices()
    await engine.suspendDataServices()
    token.replace()
    let uri = SpotifyURI("spotify:track:6rqhFgbbKwnb9MLmUQDhG6")!
    await #expect(throws: SoloistPlaybackError.pairingRequired) {
        try await engine.load(PlayRequest(contextURI: uri, startPositionMs: 1000))
    }
    await engine.retryDataServices()
    await #expect(throws: LyricFailure.unavailable) { try await engine.requestLyrics(for: uri) }
    #expect(await service.lyricRequests == 0)
    #expect(child.isRunning)
    try await engine.pause()
    try await engine.load(PlayRequest(contextURI: uri))
    await engine.shutdown()
}

@Test func soloistCommandsUseTheOwnedSocketAndRejectGuessedQueueSelection() async throws {
    let (engine, child, socket) = engineFixture()
    await engine.begin()
    try socket.emit(["type": "auth_state", "logged_in": true, "is_active": true])
    for _ in 0..<1000 { if await engine.isPaired { break }; await Task.yield() }
    try #require(await engine.isPaired)
    try await engine.preparePairing()
    try await engine.adopt(initialVolume: 0.25)
    try await engine.pause()
    #expect(socket.commands.contains("pause"))
    await #expect(throws: SoloistPlaybackError.unsupported) {
        try await engine.selectQueueEntry(QueueTarget(generation: 1, rawNextIndex: 0))
    }
    #expect(!socket.commands.contains("play"))
    await engine.shutdown()
    await engine.shutdown()
    #expect(child.stopCount == 1)
}

@Test(arguments: [RepeatMode.off, .context, .track])
func repeatCommandsFollowTheDocumentedTwoCommandTransition(mode: RepeatMode) async throws {
    let (engine, _, socket) = engineFixture()
    socket.setActions(["pause", "play", "seek", "shuffle", "set_repeat", "skip_next", "skip_prev"])
    let observations = SoloistEventFixture()
    let reader = Task { for await event in engine.events { await observations.append(event) } }
    await engine.begin()
    try socket.emit(["type": "auth_state", "logged_in": true, "is_active": true])
    try await engine.preparePairing()
    try await engine.adopt(initialVolume: 0.25)
    try await engine.setRepeat(mode)
    for _ in 0..<100 {
        if await observations.events.contains(.repeatChanged(mode)) { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    let controls = try socket.sentFrames.compactMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        .filter { ($0["command"] as? String)?.hasPrefix("set_repeat_") == true }
    let names = controls.compactMap { $0["command"] as? String }
    #expect(names == (mode == .track ? ["set_repeat_context", "set_repeat_track"] : ["set_repeat_track", "set_repeat_context"]))
    #expect(controls.compactMap { $0["enabled"] as? Bool } == [false, mode != .off])
    #expect(await observations.events.contains(.repeatChanged(mode)))
    await engine.shutdown(); await reader.value
}

@Test func shuffleAndOtherLocalControlsPublishObservedStateWithoutWebPlaybackPermission() async throws {
    let (engine, child, socket) = engineFixture(webStatus: 403)
    socket.setActions(["pause", "play", "seek", "shuffle", "set_repeat", "skip_next", "skip_prev"])
    let observations = SoloistEventFixture()
    let reader = Task { for await event in engine.events { await observations.append(event) } }
    await engine.begin()
    try socket.emit(["type": "auth_state", "logged_in": true, "is_active": true])
    try await engine.preparePairing()
    try await engine.adopt(initialVolume: 0.25)
    try await engine.setShuffle(true)
    try await engine.next()
    try await engine.previous()
    try await engine.seek(to: 1234)
    try await engine.setVolume(0.4)
    try await engine.pause()
    try await engine.resume()
    for _ in 0..<100 {
        if await observations.events.contains(.shuffleChanged(true)) { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await observations.events.contains(.shuffleChanged(true)))
    for name in ["set_shuffle", "skip_next", "skip_prev", "seek", "set_volume", "pause", "play"] {
        #expect(socket.commands.contains(name))
    }
    #expect(!SoloistHTTPFixture.paths.contains("/v1/me/player/play"))
    #expect(child.isRunning)
    await engine.shutdown(); await reader.value
}

@Test func repairingRevokesCompanionAccessAndClearsPublishedState() async throws {
    let (engine, child, socket) = engineFixture()
    let observations = SoloistEventFixture()
    let reader = Task { for await event in engine.events { await observations.append(event) } }
    await engine.begin()
    try socket.emit(["type": "auth_state", "logged_in": true, "is_active": true])
    for _ in 0..<1000 { if await engine.isPaired { break }; await Task.yield() }
    await #expect(throws: SoloistPlaybackError.pairingRequired) { try await engine.pause() }
    try await engine.preparePairing()
    await #expect(throws: SoloistPlaybackError.pairingRequired) { try await engine.pause() }
    try await engine.adopt(initialVolume: 0.25)
    try await engine.pause()
    socket.changeTrack()
    try socket.emit(["type": "auth_state", "logged_in": true, "is_active": true])
    try await Task.sleep(for: .milliseconds(30))
    await #expect(throws: SoloistPlaybackError.pairingRequired) { try await engine.pause() }
    await engine.shutdown(); await reader.value
    let events = await observations.events
    #expect(events.contains(.playbackIdle))
    #expect(!events.contains(.volumeChanged(volume: 0)), "Muted preparation must not overwrite the user's saved listening volume")
    #expect(!events.contains { if case let .trackChanged(track) = $0 { return track.uri.rawValue == "spotify:track:11dFghVXANMlKmJXsNCbNl" }; return false })
    #expect(child.stopCount == 1)
}

@Test func unavailableDataServicesNeverStopAdoptedSoloistAudio() async throws {
    let (engine, child, socket) = engineFixture()
    await engine.begin()
    try socket.emit(["type": "auth_state", "logged_in": true, "is_active": true])
    try await engine.preparePairing()
    try await engine.adopt(initialVolume: 0.25)
    await engine.retryDataServices()
    let uri = SpotifyURI("spotify:track:6rqhFgbbKwnb9MLmUQDhG6")!
    await #expect(throws: LyricFailure.unavailable) { try await engine.requestLyrics(for: uri) }
    #expect(child.isRunning && child.stopCount == 0)
    try await engine.pause()
    await engine.shutdown()
}

@Test func soloistProtocolUsesJSONTextFrames() throws {
    let data = Data(#"{"type":"command","command":"pause"}"#.utf8)
    guard case let .string(value) = try SoloistSocket.textMessage(data) else {
        Issue.record("Soloist requires a text frame"); return
    }
    #expect(value == String(decoding: data, as: UTF8.self))
}

@Test func lostSoloistSocketDoesNotDeclareTheStillRunningChildSilent() async throws {
    let (engine, child, socket) = engineFixture()
    await engine.begin()
    try socket.emit(["type": "auth_state", "logged_in": true, "is_active": true])
    for _ in 0..<1000 { if await engine.isPaired { break }; await Task.yield() }
    await socket.close()
    for _ in 0..<1000 { if await !engine.isConnected { break }; await Task.yield() }
    #expect(child.isRunning)
    #expect(child.stopCount == 0)
    await #expect(throws: SoloistPlaybackError.self) { try await engine.pause() }
    await engine.shutdown()
    #expect(child.stopCount == 1)
}

}

private actor CompanionServiceFixture: SoloistDataServices {
    var lyricRequests = 0
    func requestLyrics(for track: SpotifyURI) async throws -> TrackLyrics { lyricRequests += 1; throw LyricFailure.unavailable }
    func requestRadio(seed: SpotifyURI) async throws -> RadioMix { throw RadioFailure.unavailable }
    func requestArtistTopTracks(for track: SpotifyURI, artistIndex: Int) async throws -> ArtistTopTracks { throw ArtistTopTracksFailure.unavailable }
    func shutdown() async {}
}

private final class ServiceTokenFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var token = "fixture"
    var value: String { lock.withLock { token } }
    func replace() { lock.withLock { token = "replacement" } }
}

private actor CompanionCreationGate {
    private(set) var starts = 0
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        starts += 1
        if !released { await withCheckedContinuation { waiters.append($0) } }
    }
    func release() { released = true; waiters.forEach { $0.resume() }; waiters = [] }
}

private actor ReadableCompanionFixture: SoloistDataServices {
    private(set) var shutdowns = 0
    private(set) var requests = 0
    private var gate: CompanionCreationGate?
    func hold(on gate: CompanionCreationGate) { self.gate = gate }
    func requestLyrics(for track: SpotifyURI) async throws -> TrackLyrics {
        requests += 1
        await gate?.wait()
        return TrackLyrics(trackURI: track, synchronization: .unsynced, lines: [TrackLyricLine(text: "Fixture lyric", startTimeMs: nil)],
            provider: "fixture", providerDisplayName: "Fixture", isRightToLeft: false)
    }
    func requestRadio(seed: SpotifyURI) async throws -> RadioMix {
        requests += 1
        await gate?.wait()
        return RadioMix(contextURI: SpotifyURI("spotify:playlist:fixture")!, tracks: [])
    }
    func requestArtistTopTracks(for track: SpotifyURI, artistIndex: Int) async throws -> ArtistTopTracks {
        requests += 1
        await gate?.wait()
        return ArtistTopTracks(trackURI: track, tracks: [])
    }
    func shutdown() { shutdowns += 1 }
}

private func metadataRequest(_ operation: String, engine: SoloistEngine) async throws -> String {
    let track = SpotifyURI("spotify:track:6rqhFgbbKwnb9MLmUQDhG6")!
    switch operation {
    case "radio": return try await engine.requestRadio(seed: track).contextURI.rawValue
    case "lyrics": return try await engine.requestLyrics(for: track).trackURI.rawValue
    default: return try await engine.requestArtistTopTracks(for: track, artistIndex: 0).trackURI.rawValue
    }
}

private func expectUnavailable(_ request: Task<String, any Error>, operation: String) async {
    switch operation {
    case "radio": await #expect(throws: RadioFailure.unavailable) { _ = try await request.value }
    case "lyrics": await #expect(throws: LyricFailure.unavailable) { _ = try await request.value }
    default: await #expect(throws: ArtistTopTracksFailure.unavailable) { _ = try await request.value }
    }
}
