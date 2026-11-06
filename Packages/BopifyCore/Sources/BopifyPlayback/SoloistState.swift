import Foundation
import BopifyDomain

public enum SoloistPlaybackError: Error, Equatable, Sendable {
    case invalidState, unavailable, invalidKey, pairingRequired, accountMismatch, missingAccountID
    case ambiguousDevice, authorizationRequired, rateLimited, unsupported, startupFailed
}

/// Socket state belongs to one owned process. Nothing here invents playback confirmations.
struct SoloistState {
    private(set) var paired = false
    private(set) var authRevision: UInt64 = 0
    private(set) var active = false
    private(set) var playing = false
    private(set) var track: Track?
    private(set) var itemURI: String?
    private(set) var context: SpotifyURI?
    private(set) var positionMs: Int64 = 0
    private(set) var observedAt = Date.distantPast
    private(set) var actions: Set<String> = []
    private(set) var volume: Double?
    private var queueGeneration: UInt64 = 0
    private var speed: Double = 1
    private var publishedTrack: Track?
    private var publishedActive = false

    mutating func resetPublication() { publishedTrack = nil; publishedActive = false }

    mutating func ingest(_ data: Data, at date: Date) throws -> [PlaybackEvent] {
        guard data.count <= 1_048_576,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { throw SoloistPlaybackError.invalidState }
        switch type {
        case "auth_state":
            guard let paired = object["logged_in"] as? Bool else { throw SoloistPlaybackError.invalidState }
            authRevision &+= 1
            self.paired = paired
            active = object["is_active"] as? Bool ?? false
            return [.activeDeviceChanged(isActive: active)]
        case "playback_state":
            guard let active = object["is_active"] as? Bool, let status = object["status"] as? String,
                  ["idle", "playing", "paused", "buffering"].contains(status),
                  let position = object["position"] as? [String: Any] else { throw SoloistPlaybackError.invalidState }
            self.active = active
            playing = status == "playing"
            positionMs = try positionValue(position, at: date)
            observedAt = date
            let entity = object["item"] as? [String: Any]
            track = Self.track(entity)
            itemURI = entity?["uri"] as? String
            context = (object["context"] as? [String: Any])?["uri"].flatMap { $0 as? String }.flatMap(SpotifyURI.init)
            actions = Set((object["available_actions"] as? [String: Any] ?? [:]).keys)
            if let raw = object["volume"] as? Double, raw.isFinite, (0...100).contains(raw) { volume = raw / 100 }
            var events: [PlaybackEvent] = [.activeDeviceChanged(isActive: active), .queueSelectionSupported(false)]
            guard active else { publishedActive = false; return events }
            if status == "idle" || track == nil { events.append(.playbackIdle); resetPublication() }
            else {
                if let track, track != publishedTrack || !publishedActive { events.append(.trackChanged(track)); publishedTrack = track }
                publishedActive = true
                if status == "buffering" { events.append(.loading) }
                else { events.append(playing ? .playing(positionMs: positionMs) : .paused(positionMs: positionMs)) }
            }
            if status != "idle", let raw = itemURI, let uri = SpotifyURI(raw) {
                events.append(.recoveryIdentity(PlaybackIdentity(trackURI: uri, contextURI: context?.rawValue)))
            }
            events += [.playbackRate(speed), .availableActions(canSeek: actions.contains("seek"),
                canNext: actions.contains("skip_next"), canPrevious: actions.contains("skip_prev"))]
            if let volume { events.append(.volumeChanged(volume: volume)) }
            events += options(object["options"] as? [String: Any])
            return events
        case "device_changed":
            guard let active = object["is_active"] as? Bool else { throw SoloistPlaybackError.invalidState }
            self.active = active
            if !active { publishedActive = false }
            return [.activeDeviceChanged(isActive: active)]
        case "track_changed":
            let entity = object["item"] as? [String: Any]
            track = Self.track(entity)
            itemURI = entity?["uri"] as? String
            guard active else { return [] }
            publishedTrack = track; publishedActive = track != nil
            return track.map { [.trackChanged($0)] } ?? [.playbackIdle]
        case "playback_changed":
            guard let status = object["status"] as? String else { throw SoloistPlaybackError.invalidState }
            playing = status == "playing"
            guard active else { return [] }
            if status == "idle" { resetPublication(); return [.playbackIdle] }
            // Ask for a snapshot before presenting a position anchored to a changed phase.
            return []
        case "position_sync":
            guard let value = object["position"] as? [String: Any] else { throw SoloistPlaybackError.invalidState }
            positionMs = try positionValue(value, at: date)
            observedAt = date
            return active ? [.positionCorrection(positionMs: positionMs), .playbackRate(speed)] : []
        case "volume_changed":
            guard let volume = object["volume"] as? Double, volume.isFinite, (0...100).contains(volume) else {
                throw SoloistPlaybackError.invalidState
            }
            self.volume = volume / 100
            return active ? [.volumeChanged(volume: volume / 100)] : []
        case "options_changed": return active ? options(object["options"] as? [String: Any]) : []
        case "queue_changed":
            queueGeneration &+= 1
            func entries(_ key: String) throws -> [QueueEntry] {
                guard let items = object[key] as? [[String: Any]], items.count <= 10_000 else { throw SoloistPlaybackError.invalidState }
                return items.enumerated().map { index, item in
                    let entity = item["item"] as? [String: Any]
                    let uri = (entity?["uri"] as? String).flatMap(SpotifyURI.init)
                    let metadata = Self.track(entity)
                    return QueueEntry(id: "\(queueGeneration)-\(key)-\(index)", uri: uri,
                        target: nil, track: metadata, metadataFailed: metadata == nil)
                }
            }
            let previous = try entries("previous"), next = try entries("upcoming")
            let current = track.map { QueueEntry(id: "\(queueGeneration)-current", uri: $0.uri, target: nil, track: $0, metadataFailed: false) }
            return [.queueChanged(PlaybackQueue(generation: queueGeneration, previous: previous, current: current, next: next))]
        case "error": return [.commandRejected("unavailable")]
        default: return []
        }
    }

    private mutating func positionValue(_ value: [String: Any], at date: Date) throws -> Int64 {
        guard let ms = value["position_ms"] as? Double, let timestamp = value["timestamp_ms"] as? Double,
              let rate = value["speed"] as? Double, ms.isFinite, timestamp.isFinite, rate.isFinite,
              (0...31_536_000_000).contains(ms), (0...4).contains(rate) else { throw SoloistPlaybackError.invalidState }
        let elapsed = date.timeIntervalSince1970 * 1000 - timestamp
        guard elapsed >= -2000, rate == 0 || elapsed < 86_400_000 else { throw SoloistPlaybackError.invalidState }
        speed = rate
        return Int64(ms + max(0, elapsed) * rate)
    }

    private func options(_ value: [String: Any]?) -> [PlaybackEvent] {
        var events: [PlaybackEvent] = []
        if let shuffle = value?["shuffle"] as? Bool { events.append(.shuffleChanged(shuffle)) }
        if let mode = (value?["repeat"] as? String).flatMap(RepeatMode.init(rawValue:)) { events.append(.repeatChanged(mode)) }
        return events
    }

    static func track(_ entity: [String: Any]?) -> Track? {
        guard let entity, let raw = entity["uri"] as? String, let uri = SpotifyURI(raw),
              uri.kind == .track || uri.kind == .episode,
              let decorations = entity["decorations"] as? [String: Any],
              let title = (decorations["identity"] as? [String: Any])?["name"] as? String else { return nil }
        let creators = (decorations["creators"] as? [[String: Any]] ?? []).compactMap { creator -> ArtistSummary? in
            guard let entity = creator["entity"] as? [String: Any],
                  let d = entity["decorations"] as? [String: Any], let name = (d["identity"] as? [String: Any])?["name"] as? String else { return nil }
            return ArtistSummary(name: name)
        }
        let duration = (decorations["playback"] as? [String: Any])?["duration_ms"] as? Double ?? 0
        guard duration.isFinite, (0...31_536_000_000).contains(duration) else { return nil }
        let cover = (decorations["visual_identity"] as? [String: Any])?["cover"] as? [[String: Any]]
        let artwork = cover?.compactMap { ($0["url"] as? String).flatMap(URL.init(string:)) }.first { $0.scheme == "https" }
        let parent = (decorations["parent"] as? [String: Any])?["entity"] as? [String: Any]
        let parentDecorations = parent?["decorations"] as? [String: Any]
        let album = (parentDecorations?["identity"] as? [String: Any])?["name"] as? String
        return Track(uri: uri, title: title, artists: creators, albumTitle: album,
            artwork: artwork.map(Artwork.init(url:)), durationMs: Int64(duration))
    }
}
