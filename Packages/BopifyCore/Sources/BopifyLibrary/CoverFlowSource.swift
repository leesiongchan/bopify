import Foundation
import Observation
import BopifyDomain

/// What Cover Flow renders and drives, whichever library tab supplies it.
@MainActor
public protocol CoverFlowSource: AnyObject, Observable {
    var tracks: [Track] { get }
    var selectedURI: SpotifyURI? { get }
    var isLoading: Bool { get }
    var error: LibraryError? { get }
    var retryAfter: Date? { get }
    var hasMore: Bool { get }
    func reveal(at date: Date) async
    func hide(at date: Date)
    func select(_ uri: SpotifyURI)
    func loadMore() async
    func loadMoreIfNeeded(near uri: SpotifyURI) async
    func retry(at date: Date) async
    func playRequest(for track: Track) -> PlayRequest
}

extension LikedSongsModel: CoverFlowSource {
    /// A liked song plays on its own, as Cover Flow always has.
    public func playRequest(for track: Track) -> PlayRequest { PlayRequest(contextURI: track.uri) }
}
