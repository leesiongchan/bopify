import AppKit
import Network
import BopifyPlayback

@MainActor final class PlaybackConnectionMonitor {
    private let coordinator: PlaybackRecoveryCoordinator
    private var monitor: NWPathMonitor?
    private var observers: [NSObjectProtocol] = []
    private var generation = 0

    init(coordinator: PlaybackRecoveryCoordinator) { self.coordinator = coordinator }

    func start() {
        guard monitor == nil else { return }
        generation += 1
        let mine = generation
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor in
                guard let self, self.generation == mine, self.monitor != nil else { return }
                self.coordinator.setNetworkAvailable(available)
            }
        }
        monitor.start(queue: DispatchQueue(label: "bopify.connection"))
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == mine, self.monitor != nil else { return }
                self.coordinator.setSleeping(true)
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == mine, self.monitor != nil else { return }
                self.coordinator.wake()
            }
        })
    }

    func stop() {
        generation += 1
        monitor?.cancel()
        monitor = nil
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach(center.removeObserver)
        observers = []
    }
}
