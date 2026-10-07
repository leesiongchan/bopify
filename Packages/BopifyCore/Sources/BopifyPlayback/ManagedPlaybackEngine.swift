import BopifyDomain

public protocol ManagedPlaybackEngine: PlaybackEngine {
    func shutdown() async
}
