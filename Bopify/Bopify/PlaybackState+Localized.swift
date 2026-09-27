import SwiftUI
import BopifyDomain
import BopifyPlayback

extension PlaybackState {
    var localizedStatusText: Text {
        switch phase {
        case let .error(error): error.localizedText
        case .idle:
            switch InactiveStatus(self) {
            case let .playingOn(deviceName): Text("player.remote.title \(deviceName)")
            case let .pausedOn(deviceName): Text("player.remote.paused \(deviceName)")
            case .notPlaying: Text("player.notPlaying")
            }
        case .loading: Text("player.loading")
        case .buffering: Text("player.buffering")
        case .ended: Text("player.ended")
        case .playing: Text("transport.state.playing")
        case .paused: Text("transport.state.paused")
        }
    }
}
