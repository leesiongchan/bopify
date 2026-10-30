import SwiftUI
import BopifyDomain
import BopifyPlayback

extension PlaybackState {
    var localizedStatusText: Text {
        switch phase {
        case let .error(error): error.localizedText
        case .idle:
            switch InactiveStatus(self) {
            case let .playingOn(deviceName):
                // The device list didn't have this device, so librespot supplied no name.
                deviceName.isEmpty ? Text("player.inactiveDevice.title") : Text("player.remote.title \(deviceName)")
            case let .pausedOn(deviceName):
                deviceName.isEmpty ? Text("player.remote.pausedUnnamed") : Text("player.remote.paused \(deviceName)")
            case .notPlaying: Text("player.notPlaying")
            }
        case .loading: Text("player.loading")
        case .ended: Text("player.ended")
        case .playing: Text("transport.state.playing")
        case .paused: Text("transport.state.paused")
        }
    }
}
