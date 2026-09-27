import Foundation

public enum PlayerInteraction: Hashable, Sendable {
    case seek, volume, windowDrag, popover, menu
}

public enum PlayerAttentionEvent: Sendable {
    case visibility(Bool), pointer(Bool), keyboardFocus(Bool), accessibilityFocus(Bool)
    case interaction(PlayerInteraction, Bool)
    case reset
}

public struct PlayerAttentionState {
    public private(set) var isVisible = false
    public private(set) var isRevealed = false
    public private(set) var collapseDeadline: TimeInterval?
    private var pointer = false
    private var keyboardFocus = false
    private var accessibilityFocus = false
    private var interactions: Set<PlayerInteraction> = []

    public init() {}

    public mutating func update(_ event: PlayerAttentionEvent, at now: TimeInterval) {
        switch event {
        case .reset:
            self = Self()
            return
        case let .visibility(visible):
            if !visible { self = Self(); return }
            isVisible = true
        default:
            guard isVisible else { return }
            switch event {
            case let .pointer(value): pointer = value
            case let .keyboardFocus(value): keyboardFocus = value
            case let .accessibilityFocus(value): accessibilityFocus = value
            case let .interaction(kind, active):
                if active { interactions.insert(kind) } else { interactions.remove(kind) }
            default: break
            }
        }
        if pointer || keyboardFocus || accessibilityFocus || !interactions.isEmpty {
            isRevealed = true
            collapseDeadline = nil
        } else if isRevealed && collapseDeadline == nil {
            collapseDeadline = now + 0.280
        }
    }

    public mutating func advance(to now: TimeInterval) {
        guard let collapseDeadline, now >= collapseDeadline else { return }
        isRevealed = false
        self.collapseDeadline = nil
    }
}
