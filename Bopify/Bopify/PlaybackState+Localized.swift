import SwiftUI
import BopifyDomain

extension PlaybackState {
    var localizedStatusText: Text {
        switch phase {
        case let .error(error): error.localizedText
        case .idle: Text("player.inactiveDevice.title")
        case .loading: Text("player.loading")
        case .buffering: Text("player.buffering")
        case .ended: Text("player.ended")
        case .playing: Text("transport.state.playing")
        case .paused: Text("transport.state.paused")
        }
    }
}
