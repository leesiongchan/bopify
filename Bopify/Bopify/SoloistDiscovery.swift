import Network
import Observation
import os
import BopifyDomain

/// Observes the real Bonjour operation used by first-time Spotify Connect pairing.
@MainActor @Observable
final class SoloistDiscovery {
    enum State: Equatable, Sendable { case idle, browsing, denied, unavailable }
    private(set) var state: State = .idle
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var generation = 0

    func start() {
        guard browser == nil else { return }
        generation += 1
        let mine = generation
        let browser = NWBrowser(for: .bonjour(type: "_spotify-connect._tcp", domain: "local."), using: .tcp)
        self.browser = browser
        state = .browsing
        browser.stateUpdateHandler = { [weak self] update in
            Task { @MainActor in
                guard let self, self.generation == mine else { return }
                let state = Self.status(for: update)
                if self.state != state {
                    if state == .denied { BopifyLog.playback.notice("Soloist discovery blocked reason=localNetworkDenied") }
                    else if state == .unavailable { BopifyLog.playback.notice("Soloist discovery unavailable") }
                }
                self.state = state
            }
        }
        browser.start(queue: .main)
    }

    func stop() {
        generation += 1
        browser?.cancel()
        browser = nil
        state = .idle
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
