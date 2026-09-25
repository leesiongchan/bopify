import Foundation
import Observation
import BopifyDomain

public enum PlayerMode: String, Codable, Sendable { case expanded, compact, queue }

@MainActor
@Observable
public final class PlayerPresentation {
    public private(set) var mode: PlayerMode
    public var keepOnTop: Bool
    public var isVisible = false

    public init(mode: PlayerMode = .expanded, keepOnTop: Bool = false) {
        self.mode = mode
        self.keepOnTop = keepOnTop
    }
    public func setMode(_ mode: PlayerMode) { self.mode = mode }
    public func dismissQueue() -> Bool {
        guard mode == .queue else { return false }
        mode = .expanded
        return true
    }
}

public enum CarouselDirection: Sendable { case next, previous, fade }

public func carouselDirection(old: PlaybackQueue?, new: PlaybackQueue) -> CarouselDirection {
    guard let old, let before = old.current?.id, let after = new.current?.id,
          before != after else { return .fade }
    if old.next.first?.id == after && new.previous.last?.id == before { return .next }
    if old.previous.last?.id == after && new.next.first?.id == before { return .previous }
    return .fade
}
