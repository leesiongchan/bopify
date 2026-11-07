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
    func changeTrack() { lock.withLock { uri = "spotify:track:11dFghVXANMlKmJXsNCbNl" } }
    var position: Double { 1000 + Date().timeIntervalSince(anchor) * 1000 }
    var commands: [String] { lock.withLock { sent } }
    func send(_ data: Data) async throws {
        let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let command = value?["command"] as? String {
            lock.withLock { sent.append(command) }
            if command == "get_auth_state", lock.withLock({ failsAuthenticationRequest }) {
                throw SoloistPlaybackError.unavailable
            }
            if command == "get_auth_state", let loggedIn = lock.withLock({ authenticationReply }) {
                try emit(["type": "auth_state", "logged_in": loggedIn, "is_active": false])
            }
            if command == "set_volume", let value = value?["volume"] as? Double { lock.withLock { volume = value } }
            if command == "get_state" {
                try emit(["type": "playback_state", "is_active": lock.withLock { active }, "status": lock.withLock { playbackStatus }, "volume": lock.withLock { volume },
                    "item": ["uri": currentURI, "decorations": ["identity": ["name": "Fixture"], "playback": ["duration_ms": 100000]]],
                    "position": ["position_ms": position, "timestamp_ms": Date().timeIntervalSince1970 * 1000, "speed": 1],
                    "available_actions": ["pause": [:], "play": [:], "seek": [:]]])
            }
        }
    }
    func emit(_ object: [String: Any]) throws {
        pair.continuation.yield(SoloistFrame(data: try JSONSerialization.data(withJSONObject: object), receivedAt: .now))
    }
    func close() async { pair.continuation.finish() }
}

private final class SoloistHTTPFixture: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var playerStatus: Int?
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> Data)?
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requests: [String] = []
    static var paths: [String] { lock.withLock { requests } }
    static func reset() { lock.withLock { requests = [] } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.lock.withLock { Self.requests.append(path) }
        let data = Self.handler?(request) ?? Data()
        let status = path.hasPrefix("/v1/me/player") ? Self.playerStatus ?? Self.status : Self.status
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

private func engineFixture(webStatus: Int = 200, diagnosticFailure: SoloistPlaybackError? = nil,
    pairingPort: UInt16? = nil, publisherFactory: SoloistPairingPublisherFactory? = nil,
    webToken: @escaping @Sendable () async throws -> String = { "fixture" },
    streamingToken: @escaping @Sendable () async throws -> String = { "fixture" },
    dataToken: (@Sendable () async throws -> String)? = nil,
    playerStatus: Int? = nil, profile: [String: String]? = nil,
    serviceFactory: @escaping @Sendable (String) async throws -> any SoloistDataServices = { _ in throw PlayerError.networkUnavailable },
    pairingNow: @escaping @Sendable () -> Date = { .now }, authenticationReply: Bool? = nil,
    failsAuthenticationRequest: Bool = false) -> (SoloistEngine, SoloistChildFixture, SoloistSocketFixture) {
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
            object = profile ?? ["account_id": request.value(forHTTPHeaderField: "Authorization") == "Bearer replacement" ? "other-account" : "fixture-account"]
        } else if request.url?.path.hasSuffix("devices") == true {
            object = ["devices": [["id": "owned", "name": "Fixture", "is_restricted": false]]]
        } else {
            object = ["device": ["id": "owned", "name": "Fixture"],
                "item": ["uri": "spotify:track:6rqhFgbbKwnb9MLmUQDhG6"], "is_playing": true, "progress_ms": socket.position]
        }
        return try! JSONSerialization.data(withJSONObject: object)
    }
    let engine = SoloistEngine(child: child, api: SoloistWebAPI(session: URLSession(configuration: configuration)), baseline: [], name: "Fixture",
        webToken: webToken, streamingToken: streamingToken,
        transportFactory: { _ in socket }, serviceFactory: serviceFactory, progress: { _ in }, verificationInterval: .milliseconds(600),
        publisherFactory: publisherFactory, dataToken: dataToken, pairingNow: pairingNow)
    return (engine, child, socket)
}

@Suite("Soloist managed engine", .serialized) struct SoloistEngineTests {
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
