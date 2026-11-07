import Foundation

/// Behavioral association, never an account assertion based only on the displayed device name.
struct SoloistCorrelation {
    let baseline: Set<SoloistDevice>
    let name: String
    private var candidate: String?
    private var authRevision: UInt64?
    private var previous: (uri: String, position: Int64, webPosition: Double, webDate: Date, date: Date)?

    init(baseline: Set<SoloistDevice>, name: String) { self.baseline = baseline; self.name = name }

    mutating func observe(_ state: SoloistState, devices: Set<SoloistDevice>, playback: SoloistWebPlayback?, at date: Date) throws -> String? {
        if candidate != nil, !state.paired || !state.active || state.authRevision != authRevision {
            throw SoloistPlaybackError.pairingRequired
        }
        let matches = devices.subtracting(baseline).filter { $0.name == name && !$0.is_restricted && $0.id?.isEmpty == false }
        guard matches.count <= 1 else { throw SoloistPlaybackError.ambiguousDevice }
        guard state.paired, state.active, state.playing, let uri = state.itemURI, !uri.isEmpty,
              let id = matches.first?.id, let playback, playback.deviceID == id,
              playback.uri == uri, playback.playing,
              (0...5).contains(date.timeIntervalSince(state.observedAt)),
              (0...5).contains(date.timeIntervalSince(playback.observedAt)) else {
            if candidate != nil { throw SoloistPlaybackError.ambiguousDevice }
            return nil
        }
        let local = Double(state.positionMs) + date.timeIntervalSince(state.observedAt) * 1000
        let remote = playback.positionMs + date.timeIntervalSince(playback.observedAt) * 1000
        guard abs(local - remote) <= 3000 else {
            if candidate != nil { throw SoloistPlaybackError.ambiguousDevice }; return nil
        }
        if let candidate, candidate != id { throw SoloistPlaybackError.ambiguousDevice }
        candidate = id; authRevision = state.authRevision
        defer { previous = (uri, state.positionMs, playback.positionMs, playback.observedAt, date) }
        if let previous, previous.uri == uri, date.timeIntervalSince(previous.date) >= 0.5,
           state.positionMs > previous.position + 200,
           playback.observedAt > previous.webDate, playback.positionMs > previous.webPosition + 200 { return id }
        return nil
    }
}
