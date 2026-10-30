import Foundation
import Observation
import BopifyDomain

public protocol CoverFlowItem {
    var uri: SpotifyURI { get }
    var title: String { get }
    var subtitle: String { get }
    var artwork: Artwork? { get }
}

extension Track: CoverFlowItem {
    public var subtitle: String { artists.map(\.name).joined(separator: ", ") }
}

extension LibraryCollection: CoverFlowItem {}

/// What Cover Flow renders and drives, whichever library tab supplies it.
@MainActor
public protocol CoverFlowSource: AnyObject, Observable {
    associatedtype Item: CoverFlowItem
    var items: [Item] { get }
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
}

extension LikedSongsModel: CoverFlowSource {
    public var items: [Track] { tracks }
    /// A liked song plays on its own: the engine cannot load the Liked Songs collection at a start track.
    public func playRequest(for track: Track) -> PlayRequest { PlayRequest(contextURI: track.uri) }
}

extension RecentsModel { public var items: [Track] { tracks } }
extension ExploreModel { public var items: [Track] { tracks } }
