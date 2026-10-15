import AppKit
import Network
import BopifyPlayback

@MainActor final class PlaybackConnectionMonitor {
    private let coordinator: PlaybackRecoveryCoordinator
    private let onConnectivityRestored: @MainActor () -> Void
    private var networkAvailable: Bool?
    private var monitor: NWPathMonitor?
    private var observers: [NSObjectProtocol] = []
    private var generation = 0

    init(coordinator: PlaybackRecoveryCoordinator, onConnectivityRestored: @escaping @MainActor () -> Void = {}) {
        self.coordinator = coordinator
        self.onConnectivityRestored = onConnectivityRestored
    }

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
                let restored = self.networkAvailable == false && available
                self.networkAvailable = available
                self.coordinator.setNetworkAvailable(available)
                if restored { self.onConnectivityRestored() }
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
                self.onConnectivityRestored()
            }
        })
    }

    func stop() {
        generation += 1
        monitor?.cancel()
        monitor = nil
        networkAvailable = nil
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach(center.removeObserver)
        observers = []
    }
}
