import AppKit
import Network
import Observation
import os
import BopifyDomain

/// Observes the real Bonjour operation used by first-time Spotify Connect pairing.
@MainActor @Observable
final class SoloistDiscovery {
    enum State: Equatable, Sendable { case idle, browsing, denied, unavailable }
    enum RecoveryEvent { case networkChanged(Bool), activated }
    struct Browser {
        let start: (@escaping @MainActor (NWBrowser.State) -> Void) -> Void
        let cancel: () -> Void
    }
    private(set) var state: State = .idle
    private(set) var isReady = false
    @ObservationIgnored private let makeBrowser: () -> Browser
    @ObservationIgnored private let observeRecovery: (@escaping @MainActor (RecoveryEvent) -> Void) -> (() -> Void)
    @ObservationIgnored private let sleep: @MainActor (Duration) async throws -> Void
    @ObservationIgnored private var browser: Browser?
    @ObservationIgnored private var stopMonitoring: (() -> Void)?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var browserGeneration = 0
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var retry: Task<Void, Never>?
    @ObservationIgnored private var retryAttempt = 0
    @ObservationIgnored private var waitingForRecovery = false
    @ObservationIgnored private var networkAvailable: Bool?
    @ObservationIgnored private var onRecovery: (@MainActor () -> Void)?

    init(makeBrowser: @escaping @MainActor () -> Browser = SoloistDiscovery.nativeBrowser,
        observeRecovery: @escaping @MainActor (@escaping @MainActor (RecoveryEvent) -> Void) -> (() -> Void) = SoloistDiscovery.nativeRecovery,
        sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.makeBrowser = makeBrowser
        self.observeRecovery = observeRecovery
        self.sleep = sleep
    }

    func start(onRecovery: @escaping @MainActor () -> Void = {}) {
        guard !isStarted else { return }
        generation += 1
        let mine = generation
        isStarted = true
        self.onRecovery = onRecovery
        state = .browsing
        stopMonitoring = observeRecovery { [weak self] event in
            guard let self, self.isStarted, self.generation == mine else { return }
            switch event {
            case let .networkChanged(available):
                let restored = self.networkAvailable == false && available
                self.networkAvailable = available
                guard restored else { return }
            case .activated: break
            }
            self.recover(generation: mine)
        }
        startBrowser(generation: mine)
    }

    private func startBrowser(generation mine: Int) {
        guard isStarted, generation == mine, browser == nil else { return }
        isReady = false
        browserGeneration += 1
        let instance = browserGeneration
        let browser = makeBrowser()
        self.browser = browser
        browser.start { [weak self] update in
            guard let self, self.isStarted, self.generation == mine, self.browserGeneration == instance else { return }
            let state = Self.status(for: update)
            if self.state != state {
                if state == .denied { BopifyLog.playback.notice("Soloist discovery blocked reason=localNetworkDenied") }
                else if state == .unavailable { BopifyLog.playback.notice("Soloist discovery unavailable") }
            }
            self.state = state
            self.isReady = switch update {
            case .ready: true
            default: false
            }
            switch update {
            case .ready:
                self.retryAttempt = 0
                let recovered = self.waitingForRecovery
                self.waitingForRecovery = false
                if recovered { self.onRecovery?() }
            case .failed:
                self.waitingForRecovery = true
                self.cancelBrowser()
                if state != .denied { self.scheduleRetry(generation: mine) }
            case .waiting:
                self.waitingForRecovery = true
            default: break
            }
        }
    }

    private func scheduleRetry(generation mine: Int) {
        let delays: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8)]
        guard retry == nil, retryAttempt < delays.count else { return }
        let delay = delays[retryAttempt]
        retryAttempt += 1
        BopifyLog.playback.debug("Soloist discovery retry attempt=\(self.retryAttempt)")
        let sleep = self.sleep
        retry = Task { [weak self] in
            do { try await sleep(delay) } catch { return }
            guard let self, !Task.isCancelled, self.isStarted, self.generation == mine else { return }
            self.retry = nil
            self.startBrowser(generation: mine)
        }
    }

    private func recover(generation mine: Int) {
        retry?.cancel()
        retry = nil
        retryAttempt = 0
        if state == .denied || state == .unavailable {
            cancelBrowser()
            startBrowser(generation: mine)
        }
        onRecovery?()
    }

    private func cancelBrowser() {
        isReady = false
        browserGeneration += 1
        let browser = self.browser
        self.browser = nil
        browser?.cancel()
    }

    func stop() {
        generation += 1
        isStarted = false
        retry?.cancel()
        retry = nil
        cancelBrowser()
        stopMonitoring?()
        stopMonitoring = nil
        onRecovery = nil
        retryAttempt = 0
        waitingForRecovery = false
        networkAvailable = nil
        state = .idle
    }

    private static func nativeBrowser() -> Browser {
        let browser = NWBrowser(for: .bonjour(type: "_spotify-connect._tcp", domain: "local."), using: .tcp)
        return Browser(start: { update in
            browser.stateUpdateHandler = { state in Task { @MainActor in update(state) } }
            browser.start(queue: .main)
        }, cancel: { browser.cancel() })
    }

    private static func nativeRecovery(_ update: @escaping @MainActor (RecoveryEvent) -> Void) -> (() -> Void) {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            let available = path.status == .satisfied
            Task { @MainActor in update(.networkChanged(available)) }
        }
        monitor.start(queue: .main)
        // The non-activating status panel can become key without activating the app.
        let tokens = [NSApplication.didBecomeActiveNotification, NSWindow.didBecomeKeyNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in update(.activated) }
            }
        }
        return {
            monitor.cancel()
            for token in tokens { NotificationCenter.default.removeObserver(token) }
        }
    }

    nonisolated static func status(for state: NWBrowser.State) -> State {
        switch state {
        case let .waiting(error), let .failed(error):
            // kDNSServiceErr_PolicyDenied is the OS's explicit local-network privacy result.
            error == .dns(-65570) ? .denied : .unavailable
        case .ready: .browsing
        case .setup, .cancelled: .idle
        @unknown default: .unavailable
        }
    }
}
