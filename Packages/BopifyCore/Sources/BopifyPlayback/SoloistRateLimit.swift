import Foundation

/// The Spotify cooldown survives recreating a player or retrying setup.
actor SoloistRateLimit {
    static let shared = SoloistRateLimit()
    private let now: @Sendable () -> Date
    private(set) var retryAt = Date.distantPast

    init(now: @escaping @Sendable () -> Date = Date.init) { self.now = now }

    func check() throws {
        guard now() >= retryAt else { throw SoloistPlaybackError.rateLimited }
    }

    func postpone(seconds: Double) {
        retryAt = max(retryAt, now().addingTimeInterval(seconds.isFinite ? max(1, seconds) : 60))
    }
}
