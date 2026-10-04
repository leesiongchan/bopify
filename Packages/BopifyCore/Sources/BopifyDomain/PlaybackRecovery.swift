import Foundation

public enum SessionLossReason: String, Codable, Hashable, Sendable {
    case spircEnded, spircPanicked, playerChannelClosed, forwarderPanicked
    case commandFailed, eventStreamEnded, readinessTimeout, legacy
}
