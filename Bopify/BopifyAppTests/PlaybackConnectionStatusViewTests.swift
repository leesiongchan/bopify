import Testing
import BopifyPlayback

@MainActor @Suite("Playback connection status")
struct PlaybackConnectionStatusViewTests {
    private func view(_ status: PlaybackConnectionStatus, hasConnected: Bool) -> PlaybackConnectionStatusView {
        PlaybackConnectionStatusView(status: status, restorationUnavailable: false, hasConnected: hasConnected, onRetry: {}, onReconnect: {})
    }

    @Test(arguments: [PlaybackConnectionStatus.connecting, .restoring, .reconnecting])
    func saysConnectingUntilTheFirstConnection(status: PlaybackConnectionStatus) {
        #expect(view(status, hasConnected: false).messageKey == "connection.connecting")
        #expect(view(status, hasConnected: true).messageKey == "connection.reconnecting")
        #expect(view(status, hasConnected: false).actionKey == "connection.retry")
    }
}
