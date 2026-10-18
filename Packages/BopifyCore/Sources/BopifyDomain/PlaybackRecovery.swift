import Foundation

public enum SessionLossReason: String, Codable, Hashable, Sendable {
    case spircEnded, spircPanicked, playerChannelClosed, forwarderPanicked
    case audioOutputFailed, commandFailed, eventStreamEnded, readinessTimeout, legacy
}

public struct PlaybackIdentity: Codable, Hashable, Sendable {
    public let trackURI: SpotifyURI
    public let trackUID: String?
    public let contextURI: String?

    public init(trackURI: SpotifyURI, trackUID: String? = nil, contextURI: String? = nil) {
        self.trackURI = trackURI
        self.trackUID = trackUID
        self.contextURI = contextURI
    }

    private enum CodingKeys: String, CodingKey { case trackURI = "trackUri", trackUID = "trackUid", contextURI = "contextUri" }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let uri = SpotifyURI(try c.decode(String.self, forKey: .trackURI)), uri.kind == .track || uri.kind == .episode else {
            throw DecodingError.dataCorruptedError(forKey: .trackURI, in: c, debugDescription: "invalid playback URI")
        }
        self.init(trackURI: uri, trackUID: try c.decodeIfPresent(String.self, forKey: .trackUID), contextURI: try c.decodeIfPresent(String.self, forKey: .contextURI))
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(trackURI.rawValue, forKey: .trackURI)
        try c.encodeIfPresent(trackUID, forKey: .trackUID)
        try c.encodeIfPresent(contextURI, forKey: .contextURI)
    }
}

public struct PlaybackRecoverySnapshot: Codable, Equatable, Sendable {
    public let wasActive: Bool
    public let shouldResume: Bool
    public let identity: PlaybackIdentity?
    public let positionMs: Int64
    public let volume: Double
    public let shuffleEnabled: Bool
    public let repeatMode: RepeatMode

    public init(wasActive: Bool, shouldResume: Bool, identity: PlaybackIdentity?, positionMs: Int64, volume: Double, shuffleEnabled: Bool, repeatMode: RepeatMode) {
        self.wasActive = wasActive
        self.shouldResume = shouldResume
        self.identity = identity
        self.positionMs = positionMs
        self.volume = volume
        self.shuffleEnabled = shuffleEnabled
        self.repeatMode = repeatMode
    }
}

public enum PlaybackStartupMode: String, Codable, Sendable { case coldLaunch, recovery }

public struct PlaybackEngineConfiguration: Codable, Equatable, Sendable {
    public let deviceID: String
    public let startup: PlaybackStartupMode
    public let snapshot: PlaybackRecoverySnapshot?
    public let initialVolume: Double?
    public init(deviceID: String, startup: PlaybackStartupMode, snapshot: PlaybackRecoverySnapshot? = nil, initialVolume: Double? = nil) {
        self.deviceID = deviceID
        self.startup = startup
        self.snapshot = snapshot
        self.initialVolume = initialVolume
    }
    private enum CodingKeys: String, CodingKey { case deviceID = "deviceId", startup, snapshot, initialVolume }
}

public enum PlaybackBootstrapOutcome: Hashable, Sendable {
    case local(PlaybackIdentity), remote, unavailable
}
