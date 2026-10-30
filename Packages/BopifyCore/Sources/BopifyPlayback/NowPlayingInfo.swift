import Foundation
import BopifyDomain

public struct NowPlayingInfo: Equatable, Sendable {
    public let title: String
    public let artist: String
    public let album: String?
    public let artworkURL: URL?
    public let durationMs: Int64
    public let elapsedMs: Int64
    public let isPlaying: Bool
    public let canNext: Bool
    public let canPrevious: Bool
    public let canSeek: Bool

    public init(title: String, artist: String, album: String?, artworkURL: URL?, durationMs: Int64, elapsedMs: Int64,
                isPlaying: Bool, canNext: Bool, canPrevious: Bool, canSeek: Bool) {
        self.title = title; self.artist = artist; self.album = album; self.artworkURL = artworkURL
        self.durationMs = durationMs; self.elapsedMs = elapsedMs; self.isPlaying = isPlaying
        self.canNext = canNext; self.canPrevious = canPrevious; self.canSeek = canSeek
    }
}

/// Nil unless Bopify is the device playing, so media keys reach other apps while it only mirrors another device.
/// `positionMs` is the player's display position, so Now Playing's clock matches Bopify's own.
public func nowPlayingInfo(for state: PlaybackState, positionMs: Int64, connectionReady: Bool = true) -> NowPlayingInfo? {
    guard connectionReady, state.isActiveDevice, let track = state.currentTrack else { return nil }
    return NowPlayingInfo(title: track.title, artist: track.artists.map(\.name).joined(separator: ", "),
                          album: track.albumTitle, artworkURL: track.artwork?.url, durationMs: state.durationMs,
                          elapsedMs: positionMs, isPlaying: state.phase == .playing, canNext: state.canNext,
                          canPrevious: state.canPrevious, canSeek: state.canSeek && state.durationMs > 0)
}
