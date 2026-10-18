import Foundation
import Observation
import os
import BopifyDomain

@MainActor @Observable
public final class ArtistSongsModel {
    public private(set) var result: ArtistTopTracks?
    public private(set) var isLoading = false
    public private(set) var error: ArtistTopTracksFailure?
    @ObservationIgnored private var generation = 0

    public init() {}

    public func load(for track: SpotifyURI, request: @MainActor (SpotifyURI) async throws -> ArtistTopTracks) async {
        generation += 1
        let current = generation
        result = nil
        error = nil
        isLoading = true
        defer { if generation == current { isLoading = false } }
        BopifyLog.library.debug("artist popular songs loading")
        do {
            let response = try await request(track)
            guard generation == current, !Task.isCancelled else { return }
            guard response.trackURI == track else { throw ArtistTopTracksFailure.unavailable }
            result = response
            BopifyLog.library.debug("artist popular songs ready count=\(response.tracks.count, privacy: .public)")
        } catch {
            guard generation == current, !Task.isCancelled else { return }
            self.error = error as? ArtistTopTracksFailure ?? .unavailable
            BopifyLog.library.debug("artist popular songs failed")
        }
    }

    public func cancel() {
        generation += 1
        result = nil
        error = nil
        isLoading = false
    }

    public func playRequest(for track: Track) -> PlayRequest? {
        guard let result, result.tracks.contains(where: { $0.uri == track.uri }) else { return nil }
        return PlayRequest(contextURI: track.uri)
    }
}
