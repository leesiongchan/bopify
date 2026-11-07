import Foundation
import Testing
import BopifyDomain
@testable import BopifyPlayback

private final class SoloistChildFixture: SoloistProcessHandle, @unchecked Sendable {
    let endpointURL = URL(string: "ws://127.0.0.1:12345")!
    private let lock = NSLock()
    private var stops = 0
    var stopCount: Int { lock.withLock { stops } }
    var isRunning: Bool { stopCount == 0 }
    func stop() async { lock.withLock { stops += 1 } }
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
    func setActive(_ value: Bool) { lock.withLock { active = value } }
    var currentURI: String { lock.withLock { uri } }
    func changeTrack() { lock.withLock { uri = "spotify:track:11dFghVXANMlKmJXsNCbNl" } }
    var position: Double { 1000 + Date().timeIntervalSince(anchor) * 1000 }
    var commands: [String] { lock.withLock { sent } }
    func send(_ data: Data) async throws {
        let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let command = value?["command"] as? String {
            lock.withLock { sent.append(command) }
            if command == "set_volume", let value = value?["volume"] as? Double { lock.withLock { volume = value } }
            if command == "get_state" {
                try emit(["type": "playback_state", "is_active": lock.withLock { active }, "status": "playing", "volume": lock.withLock { volume },
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
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let data = Self.handler?(request) ?? Data()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: ["Retry-After": "3600"])!, cacheStoragePolicy: .notAllowed)
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

private func engineFixture(webStatus: Int = 200, webToken: @escaping @Sendable () async throws -> String = { "fixture" },
    streamingToken: @escaping @Sendable () async throws -> String = { "fixture" },
    serviceFactory: @escaping @Sendable (String) async throws -> any SoloistDataServices = { _ in throw PlayerError.networkUnavailable }) -> (SoloistEngine, SoloistChildFixture, SoloistSocketFixture) {
    let child = SoloistChildFixture(), socket = SoloistSocketFixture()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SoloistHTTPFixture.self]
    SoloistHTTPFixture.status = webStatus
    SoloistHTTPFixture.handler = { request in
        let object: [String: Any]
        if request.url?.path == "/v1/me" {
            object = ["account_id": request.value(forHTTPHeaderField: "Authorization") == "Bearer replacement" ? "other-account" : "fixture-account"]
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
        transportFactory: { _ in socket }, serviceFactory: serviceFactory, progress: { _ in }, verificationInterval: .milliseconds(600))
    return (engine, child, socket)
}

@Suite("Soloist managed engine", .serialized) struct SoloistEngineTests {
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
    let (engine, child, socket) = engineFixture(webToken: { Issue.record("Inactive Core must not query the Web API"); throw SoloistPlaybackError.rateLimited })
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

@Test func companionRequestsStayGatedUntilBackgroundAccountAndDeviceProofCompletes() async throws {
    let service = CompanionServiceFixture()
    let (engine, _, socket) = engineFixture(serviceFactory: { _ in service })
    await engine.begin()
    try socket.emit(["type": "auth_state", "logged_in": true, "is_active": true])
    try await engine.preparePairing()
    try await engine.adopt(initialVolume: 0.25)
    let uri = SpotifyURI("spotify:track:6rqhFgbbKwnb9MLmUQDhG6")!
    await #expect(throws: LyricFailure.unavailable) { try await engine.requestLyrics(for: uri) }
    #expect(await service.lyricRequests == 0)
    await engine.retryDataServices()
    await #expect(throws: LyricFailure.unavailable) { try await engine.requestLyrics(for: uri) }
    #expect(await service.lyricRequests == 1)
    try socket.emit(["type": "auth_state", "logged_in": false, "is_active": false])
    for _ in 0..<1000 { if await !engine.isPaired { break }; await Task.yield() }
    await #expect(throws: LyricFailure.unavailable) { try await engine.requestLyrics(for: uri) }
    #expect(await service.lyricRequests == 1)
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
