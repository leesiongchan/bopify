import Foundation
import Darwin
import Testing
import BopifyDomain
@testable import BopifyPlayback

private let sampleURI = "spotify:track:6rqhFgbbKwnb9MLmUQDhG6"
private let stateDate = Date(timeIntervalSince1970: 1_800_000_000)
private func frame(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
private func snapshot(active: Bool = true, status: String = "playing") -> [String: Any] {
    ["type": "playback_state", "is_active": active, "status": status, "volume": 25,
     "item": ["uri": sampleURI, "decorations": ["identity": ["name": "Fixture"], "playback": ["duration_ms": 100000]]],
     "position": ["position_ms": 1000, "timestamp_ms": 1800000000000, "speed": 1.0],
     "options": ["repeat": "off", "shuffle": false], "available_actions": ["seek": [:]]]
}

@Test func soloistInactiveStateNeverClaimsLocalPlayback() throws {
    var state = SoloistState()
    let events = try state.ingest(frame(snapshot(active: false)), at: stateDate)
    #expect(!events.contains(.playing(positionMs: 1000)))
    #expect(events.contains(.activeDeviceChanged(isActive: false)))
    #expect(!state.active)
}

@Test func soloistStateHonorsRestrictionsAndMetadataAndIdle() throws {
    var state = SoloistState()
    let events = try state.ingest(frame(snapshot()), at: stateDate)
    #expect(events.contains(.availableActions(canSeek: true, canNext: false, canPrevious: false)))
    #expect(events.contains(.availablePlaybackOptions(canShuffle: false, canRepeat: false)))
    #expect(state.track?.title == "Fixture")
    #expect(state.positionMs == 1000)
    let idle = try state.ingest(frame(snapshot(status: "idle")), at: stateDate)
    #expect(idle.contains(.playbackIdle))
    #expect(!idle.contains(.endOfTrack))
}

@Test func soloistOnlyAdvertisesShuffleAndRepeatWhenTheCurrentContextAllowsThem() throws {
    var state = SoloistState()
    var value = snapshot()
    value["available_actions"] = ["shuffle": [:], "set_repeat": [:]]
    let supported = try state.ingest(frame(value), at: stateDate)
    #expect(supported.contains(.availablePlaybackOptions(canShuffle: true, canRepeat: true)))
    let inactive = try state.ingest(frame(snapshot(active: false)), at: stateDate)
    #expect(inactive.contains(.availablePlaybackOptions(canShuffle: false, canRepeat: false)))
}

@Test func soloistQueueKeepsDuplicateOccurrencesWithoutInventedSelection() throws {
    var state = SoloistState()
    _ = try state.ingest(frame(snapshot()), at: stateDate)
    let item: [String: Any] = ["uid": sampleURI, "item": ["uri": sampleURI]]
    let events = try state.ingest(frame(["type": "queue_changed", "previous": [], "upcoming": [item, item]]), at: stateDate)
    let queue = try #require(events.compactMap { event -> PlaybackQueue? in
        if case let .queueChanged(queue) = event { return queue }; return nil
    }.first)
    #expect(queue.next.count == 2)
    #expect(Set(queue.next.map(\.id)).count == 2)
    #expect(queue.next.allSatisfy { $0.target == nil })
}

@Test func soloistRepeatedSnapshotsDoNotInventAnotherTrackOccurrence() throws {
    var state = SoloistState()
    _ = try state.ingest(frame(snapshot()), at: stateDate)
    let events = try state.ingest(frame(snapshot()), at: stateDate)
    #expect(!events.contains { if case .trackChanged = $0 { return true }; return false })
}

@Test func soloistQueueRefreshPreservesTheCurrentOccurrenceForLyrics() throws {
    var state = SoloistState()
    _ = try state.ingest(frame(snapshot()), at: stateDate)
    let item: [String: Any] = ["uid": sampleURI, "item": ["uri": sampleURI]]
    func currentID(_ events: [PlaybackEvent]) -> String? {
        events.compactMap { event -> String? in
            if case let .queueChanged(queue) = event { return queue.current?.id }
            return nil
        }.first
    }
    let first = try #require(currentID(state.ingest(frame(["type": "queue_changed", "previous": [], "upcoming": [item]]), at: stateDate)))
    let refresh = try #require(currentID(state.ingest(frame(["type": "queue_changed", "previous": [], "upcoming": [item]]), at: stateDate)))
    let edit = try #require(currentID(state.ingest(frame(["type": "queue_changed", "previous": [], "upcoming": [item, item]]), at: stateDate)))
    #expect(refresh == first)
    #expect(edit == first)

    let sameTrack = try #require(snapshot()["item"] as? [String: Any])
    _ = try state.ingest(frame(["type": "track_changed", "item": sameTrack]), at: stateDate)
    let nextOccurrence = try #require(currentID(state.ingest(frame(["type": "queue_changed", "previous": [item], "upcoming": [item]]), at: stateDate)))
    #expect(nextOccurrence != first, "A consecutive occurrence of the same song must still restart its lyrics")
}

@Test func soloistBufferingDoesNotPretendPlaybackWasPaused() throws {
    var state = SoloistState()
    let events = try state.ingest(frame(snapshot(status: "buffering")), at: stateDate)
    #expect(events.contains(.loading))
    #expect(!events.contains(.paused(positionMs: 1000)))
}

@Test func soloistPausedPositionCanKeepAnOldNonAdvancingAnchor() throws {
    var state = SoloistState()
    var value = snapshot(status: "paused")
    value["position"] = ["position_ms": 5000, "timestamp_ms": 0, "speed": 0]
    let events = try state.ingest(frame(value), at: stateDate)
    #expect(events.contains(.paused(positionMs: 5000)))
}

@Test(arguments: ["inactive", "idle"])
func soloistReactivationPublishesMetadataThatWasNotVisibleDuringAnInterruption(interruption: String) throws {
    var state = SoloistState()
    _ = try state.ingest(frame(snapshot()), at: stateDate)
    var interrupted = snapshot(active: interruption != "inactive", status: interruption == "idle" ? "idle" : "playing")
    if interruption == "inactive" {
        interrupted["item"] = ["uri": "spotify:track:11dFghVXANMlKmJXsNCbNl", "decorations": ["identity": ["name": "Second"], "playback": ["duration_ms": 200000]]]
    }
    _ = try state.ingest(frame(interrupted), at: stateDate)
    interrupted["is_active"] = true; interrupted["status"] = "playing"
    let events = try state.ingest(frame(interrupted), at: stateDate)
    #expect(events.contains { if case .trackChanged = $0 { return true }; return false })
}

@Test func soloistRuntimeEndpointRejectsNonLoopbackAndSymlinks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("127.0.0.1".utf8).write(to: root.appendingPathComponent("ws.addr"))
    try Data("12345".utf8).write(to: root.appendingPathComponent("ws.port"))
    #expect(try SoloistProcess.endpoint(in: root).absoluteString == "ws://127.0.0.1:12345")
    try Data("192.168.1.1".utf8).write(to: root.appendingPathComponent("ws.addr"))
    #expect(throws: SoloistPlaybackError.self) { try SoloistProcess.endpoint(in: root) }
    try FileManager.default.removeItem(at: root.appendingPathComponent("ws.addr"))
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("ws.addr"), withDestinationURL: root.appendingPathComponent("ws.port"))
    #expect(throws: SoloistPlaybackError.self) { try SoloistProcess.endpoint(in: root) }
}

@Test func soloistSessionCleanupRefusesALiveProcessWithoutSignallingIt() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("data"), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(FileManager.default.createFile(atPath: root.appendingPathComponent("process.lock").path,
        contents: Data(), attributes: [.posixPermissions: 0o600]))
    let pid = root.appendingPathComponent("data/soloist.pid")
    try Data(String(getpid()).utf8).write(to: pid)
    #expect(throws: SoloistPlaybackError.self) { try SoloistProcess.clearSession(in: root) }
    #expect(FileManager.default.fileExists(atPath: pid.path))
    try FileManager.default.removeItem(at: pid)
    try SoloistProcess.clearSession(in: root)
    #expect(!FileManager.default.fileExists(atPath: root.path))
}

@Test func soloistRejectsMalformedAndStalePositionFrames() throws {
    for data in [Data("{}".utf8), Data(repeating: 32, count: 1_048_577)] {
        var state = SoloistState()
        #expect(throws: SoloistPlaybackError.self) { try state.ingest(data, at: stateDate) }
    }
    var state = SoloistState()
    #expect(throws: SoloistPlaybackError.self) {
        try state.ingest(frame(snapshot()), at: stateDate.addingTimeInterval(90_000))
    }
}

@Test func soloistRejectsUnknownGranularPlaybackStatus() throws {
    var state = SoloistState()
    _ = try state.ingest(frame(snapshot()), at: stateDate)
    #expect(throws: SoloistPlaybackError.invalidState) {
        try state.ingest(frame(["type": "playback_changed", "status": "unexpected"]), at: stateDate)
    }
    #expect(state.playbackStatus == "playing")
}

@MainActor @Test func playerHonorsProviderActionsAndIdleWithoutPhantomTrack() {
    let model = PlayerModel()
    let track = Track(uri: SpotifyURI(sampleURI)!, title: "Fixture", artists: [], albumTitle: nil, artwork: nil, durationMs: 100000)
    model.applyPreviewEvents([.trackChanged(track), .playing(positionMs: 1000),
        .availableActions(canSeek: false, canNext: false, canPrevious: false)])
    #expect(!model.state.canSeek && !model.state.canNext && !model.state.canPrevious)
    model.applyPreviewEvents([.playbackIdle])
    #expect(model.state.currentTrack == nil)
    #expect(model.state.phase == .idle)
    #expect(model.state.positionMs == 0)
}

@MainActor @Test func playerResetsProviderRateAndQueueCapabilitiesWhenReplacingAnEngine() {
    let model = PlayerModel()
    model.applyPreviewEvents([.playbackRate(0), .queueSelectionSupported(false)])
    #expect(!model.state.supportsQueueSelection)
    model.attachEngine(StubPlaybackEngine(), epoch: 1)
    #expect(model.state.playbackRate == 1)
    #expect(model.state.supportsQueueSelection)
    model.stop()
}

@Test func assistedLoadsRequireSupportedOffsetsAndExplicitDevice() throws {
    let track = SpotifyURI(sampleURI)!
    let album = SpotifyURI("spotify:album:4aawyAB9vmqN3uQ7FjRGTy")!
    let body = try SoloistWebAPI.playBody(PlayRequest(contextURI: album, startTrackURI: track, startPositionMs: 5000))
    #expect((body["offset"] as? [String: String])?["uri"] == sampleURI)
    #expect(body["position_ms"] as? Int64 == 5000)
    let artist = SpotifyURI("spotify:artist:06HL4z0CvFAxyc27GXpf02")!
    #expect(throws: SoloistPlaybackError.self) { try SoloistWebAPI.playBody(PlayRequest(contextURI: artist, startTrackURI: track)) }
}

@Test func explicitPlaybackContextsReplaceTheAutomaticOrderWithoutInventedURIs() throws {
    let selected = SpotifyURI(sampleURI)!, next = SpotifyURI("spotify:track:11dFghVXANMlKmJXsNCbNl")!
    let body = try SoloistWebAPI.playBody(PlayRequest(contextURI: selected, startPositionMs: 5500,
        followingTrackURIs: [selected, next, next]))
    #expect(body["uris"] as? [String] == [selected.rawValue, next.rawValue])
    #expect(body["position_ms"] as? Int64 == 5500)
    #expect(body["context_uri"] == nil && body["offset"] == nil)
}

@Test func soloistCorrelationRequiresFreshMatchingAdvancingOwnedPlayback() throws {
    let device = SoloistDevice(id: "owned", name: "Bopify fixture", is_restricted: false)
    var proof = SoloistCorrelation(baseline: [], name: device.name)
    var state = SoloistState()
    _ = try state.ingest(frame(["type": "auth_state", "logged_in": true, "is_active": true]), at: stateDate)
    _ = try state.ingest(frame(snapshot()), at: stateDate)
    let first = SoloistWebPlayback(deviceID: "owned", deviceName: device.name, uri: sampleURI,
        positionMs: 1000, playing: true, observedAt: stateDate, track: nil)
    #expect(try proof.observe(state, devices: [device], playback: first, at: stateDate) == nil)
    let secondDate = stateDate.addingTimeInterval(1)
    var secondState = snapshot()
    secondState["position"] = ["position_ms": 2000, "timestamp_ms": 1800000001000, "speed": 1.0]
    _ = try state.ingest(frame(secondState), at: secondDate)
    let second = SoloistWebPlayback(deviceID: "owned", deviceName: device.name, uri: sampleURI,
        positionMs: 2000, playing: true, observedAt: secondDate, track: nil)
    #expect(try proof.observe(state, devices: [device], playback: second, at: secondDate) == "owned")
    _ = try state.ingest(frame(["type": "device_changed", "is_active": false]), at: secondDate)
    #expect(throws: SoloistPlaybackError.self) { try proof.observe(state, devices: [device], playback: second, at: secondDate) }
}

@Test func soloistCorrelationRejectsFreshButStationaryWebPlayback() throws {
    let device = SoloistDevice(id: "owned", name: "Fixture", is_restricted: false)
    var proof = SoloistCorrelation(baseline: [], name: device.name), state = SoloistState()
    _ = try state.ingest(frame(["type": "auth_state", "logged_in": true, "is_active": true]), at: stateDate)
    for (offset, position) in [(0.0, 7500.0), (5.0, 12500.0)] {
        let date = stateDate.addingTimeInterval(offset)
        var value = snapshot()
        value["position"] = ["position_ms": position, "timestamp_ms": date.timeIntervalSince1970 * 1000, "speed": 1]
        _ = try state.ingest(frame(value), at: date)
        let web = SoloistWebPlayback(deviceID: "owned", deviceName: device.name, uri: sampleURI,
            positionMs: 10000, playing: true, observedAt: date, track: nil)
        #expect(try proof.observe(state, devices: [device], playback: web, at: date) == nil)
    }
}
