import BopifyDomain

public protocol ManagedPlaybackEngine: PlaybackEngine {
    func shutdown() async
}

/// A muted incoming player can be prepared while the outgoing engine remains available.
/// Call adopt only after outgoing audio has been stopped and joined.
public protocol PreparedPlaybackEngine: ManagedPlaybackEngine {
    func adopt(initialVolume: Double) async throws
    func activateForSetup() async throws
    func suspendDataServices() async
    func retryDataServices() async
}
