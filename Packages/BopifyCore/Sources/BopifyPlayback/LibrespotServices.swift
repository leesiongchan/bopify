import BopifyDomain

/// Metadata transport only; its native session creates no Player, Mixer or Spirc.
public final class LibrespotServices: Sendable {
    private let engine: LibrespotEngine
    public init(accessToken: String) async throws {
        engine = try await LibrespotEngine(accessToken: accessToken, deviceName: "Bopify services",
            configuration: PlaybackEngineConfiguration(deviceID: "bopify-services", startup: .coldLaunch), servicesOnly: true)
    }
    public func requestRadio(seed: SpotifyURI) async throws -> RadioMix { try await engine.requestRadio(seed: seed) }
    public func requestLyrics(for track: SpotifyURI) async throws -> TrackLyrics { try await engine.requestLyrics(for: track) }
    public func requestArtistTopTracks(for track: SpotifyURI, artistIndex: Int) async throws -> ArtistTopTracks {
        try await engine.requestArtistTopTracks(for: track, artistIndex: artistIndex)
    }
    public func shutdown() async { await engine.shutdown() }
}
