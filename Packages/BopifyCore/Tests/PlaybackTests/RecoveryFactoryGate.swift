import Foundation
import BopifyDomain
import BopifyPlayback

@MainActor final class RecoveryFactoryGate {
    var configurations: [PlaybackEngineConfiguration] = []
    var tokens: [String] = []
    private var pending: [CheckedContinuation<any ManagedPlaybackEngine, any Error>] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var concurrent = 0
    var maximumConcurrentCreations = 0
    func create(token: String, configuration: PlaybackEngineConfiguration) async throws -> any ManagedPlaybackEngine {
        configurations.append(configuration); tokens.append(token)
        concurrent += 1; maximumConcurrentCreations = max(concurrent, maximumConcurrentCreations)
        defer { concurrent -= 1 }
        return try await withCheckedThrowingContinuation { continuation in
            pending.append(continuation)
            for (target, waiter) in waiters where configurations.count >= target { waiter.resume() }
            waiters.removeAll { configurations.count >= $0.0 }
        }
    }
    func succeedNext(with engine: RecoveryStubEngine) { pending.removeFirst().resume(returning: engine) }
    func failNext(with error: PlayerError) { pending.removeFirst().resume(throwing: error) }
    func waitForCreationCount(_ count: Int) async {
        if configurations.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
}
