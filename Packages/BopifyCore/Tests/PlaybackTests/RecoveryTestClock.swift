import Foundation

@MainActor final class RecoveryTestClock {
    var now: TimeInterval = 0
    private var waiting: [UUID: (TimeInterval, Duration, CheckedContinuation<Void, any Error>)] = [:]
    var pendingDelays: [Duration] { waiting.values.map { $0.1 } }
    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
                waiting[id] = (now + seconds, duration, continuation)
            }
        } onCancel: { Task { @MainActor in self.waiting.removeValue(forKey: id)?.2.resume(throwing: CancellationError()) } }
    }
    func advance(by duration: Duration) {
        now += Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        for id in waiting.filter({ $0.value.0 <= now }).keys { waiting.removeValue(forKey: id)?.2.resume() }
    }
}
